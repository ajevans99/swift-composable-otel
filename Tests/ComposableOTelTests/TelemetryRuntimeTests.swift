import Foundation
import OpenTelemetrySdk
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

private let runtimeSentinelSecret = "runtime-sentinel-secret"

@Suite("Production telemetry runtime", .serialized)
struct TelemetryRuntimeTests {
  @Suite("Configuration")
  struct ConfigurationTests {
    @Test("rejects insecure and malformed production endpoints")
    func rejectsInvalidEndpoints() throws {
      let valid = URL(string: "https://gateway.example.test/otlp")!
      let cases: [(URL, TelemetryRuntimeConfigurationError)] = [
        (
          URL(string: "http://gateway.example.test/otlp")!,
          .endpointMustUseTLS(signal: .traces)
        ),
        (
          URL(string: "https:///otlp")!,
          .endpointMissingHost(signal: .traces)
        ),
        (
          URL(string: "https://user:password@gateway.example.test/otlp")!,
          .endpointContainsCredentials(signal: .traces)
        ),
        (
          URL(string: "https://gateway.example.test/otlp?secret=value")!,
          .endpointContainsQueryOrFragment(signal: .traces)
        ),
      ]

      for (traces, expected) in cases {
        #expect(throws: expected) {
          _ = try makeRuntime(
            endpoints: .init(traces: traces, metrics: valid, logs: valid)
          )
        }
      }
    }

    @Test("rejects unbounded and invalid delivery limits")
    func rejectsInvalidLimits() {
      var configuration = runtimeConfiguration()
      configuration.traces.maximumQueueSize = 0
      #expect(throws: TelemetryRuntimeConfigurationError.invalidBatchLimits) {
        _ = try makeRuntime(configuration: configuration)
      }

      configuration = runtimeConfiguration()
      configuration.delivery.retry.maximumAttempts = 0
      #expect(throws: TelemetryRuntimeConfigurationError.invalidDeliveryLimits) {
        _ = try makeRuntime(configuration: configuration)
      }

      configuration = runtimeConfiguration()
      configuration.persistence = .init(
        directory: URL(string: "https://gateway.example.test/spool")!
      )
      #expect(throws: TelemetryRuntimeConfigurationError.invalidPersistenceLimits) {
        _ = try makeRuntime(configuration: configuration)
      }
    }
  }

  @Suite("Batching")
  struct BatchingTests {
    @Test("exports a scheduled batch using an injected clock")
    func scheduledBatch() async throws {
      let clock = TestRuntimeClock()
      let capture = BatchCapture<Int>()
      let queue = RuntimeBatchQueue<Int>(
        configuration: .init(
          maximumQueueSize: 4,
          maximumBatchSize: 2,
          scheduledDelay: .seconds(5)
        ),
        signal: .traces,
        diagnostics: RuntimeDiagnosticsState(handler: nil),
        clock: clock.runtimeClock,
        export: { values, _ in
          capture.append(values)
          return true
        },
        shutdownExporter: { _ in }
      )

      queue.offer(1)
      try await eventually { clock.pendingSleeps == 1 }
      clock.advance(by: .seconds(5))
      try await eventually { capture.values == [[1]] }
      await queue.shutdown()
    }

    @Test("drops the oldest queued item deterministically while an export is active")
    func deterministicOverflow() async throws {
      let capture = BatchCapture<Int>()
      let firstExportStarted = DispatchSemaphore(value: 0)
      let releaseFirstExport = DispatchSemaphore(value: 0)
      let queue = RuntimeBatchQueue<Int>(
        configuration: .init(
          maximumQueueSize: 2,
          maximumBatchSize: 2,
          scheduledDelay: .seconds(60),
          overflowPolicy: .dropOldest
        ),
        signal: .logs,
        diagnostics: RuntimeDiagnosticsState(handler: nil),
        clock: .live,
        export: { values, _ in
          if values == [1, 2] {
            firstExportStarted.signal()
            _ = releaseFirstExport.wait(timeout: .now() + 2)
          }
          capture.append(values)
          return true
        },
        shutdownExporter: { _ in }
      )

      queue.offer(1)
      queue.offer(2)
      #expect(await wait(for: firstExportStarted, timeout: 1) == .success)
      queue.offer(3)
      queue.offer(4)
      queue.offer(5)
      releaseFirstExport.signal()
      await queue.forceFlush()

      #expect(capture.values == [[1, 2], [4, 5]])
      await queue.shutdown()
    }
  }

  @Suite("Delivery")
  struct DeliveryTests {
    @Test("retries classified responses with exponential jitter and refreshes auth")
    func retryBackoffAndAuthRefresh() async throws {
      let clock = TestRuntimeClock(randomUnit: 1)
      let transport = ScriptedTransport([.status(503), .status(202)])
      let auth = AuthRecorder()
      let engine = makeDeliveryEngine(
        clock: clock,
        transport: transport.transport,
        authenticator: .init { request in
          await auth.authorize(request)
        },
        delivery: .init(
          requestTimeout: .seconds(20),
          retry: .init(
            maximumAttempts: 3,
            initialBackoff: .seconds(2),
            maximumBackoff: .seconds(10),
            jitterRatio: 0.5
          )
        )
      )

      await engine.start()
      #expect(await engine.enqueue(request: testRequest(), signal: .traces))
      try await eventually { await transport.requestCount == 1 }
      try await eventually {
        clock.pendingDurations.contains(.seconds(3))
      }
      clock.advance(by: .seconds(3))
      try await eventually { await transport.requestCount == 2 }
      try await eventually { await engine.pendingBySignal()[.traces] == 0 }

      #expect(await auth.headers == ["Bearer token-1", "Bearer token-2"])
    }

    @Test("times out a cancelled transport without exceeding its retry budget")
    func requestTimeout() async throws {
      let clock = TestRuntimeClock()
      let transport = ScriptedTransport([.suspend])
      let engine = makeDeliveryEngine(
        clock: clock,
        transport: transport.transport,
        delivery: .init(
          requestTimeout: .seconds(4),
          retry: .init(maximumAttempts: 1)
        )
      )

      await engine.start()
      #expect(await engine.enqueue(request: testRequest(), signal: .metrics))
      try await eventually { await transport.requestCount == 1 }
      clock.advance(by: .seconds(4))
      try await eventually { await engine.pendingBySignal()[.metrics] == 0 }
    }

    @Test("an unavailable export hint pauses and bounds background flush")
    func backgroundDeadline() async throws {
      let clock = TestRuntimeClock()
      let transport = ScriptedTransport([.status(202)])
      let engine = makeDeliveryEngine(clock: clock, transport: transport.transport)
      await engine.setCondition(.unavailable)
      #expect(await engine.enqueue(request: testRequest(), signal: .logs))

      let flush = Task {
        await engine.flush(timeout: .seconds(5))
      }
      try await eventually { clock.pendingSleeps > 0 }
      clock.advance(by: .seconds(5))
      #expect(await flush.value == false)
      #expect(await transport.requestCount == 0)
    }

    @Test("isolates non-retryable exporter failure from feature execution")
    func exporterFailureIsolation() async throws {
      let transport = ScriptedTransport([.status(400)])
      var configuration = runtimeConfiguration(
        signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false)
      )
      configuration.traces = .init(maximumQueueSize: 1, maximumBatchSize: 1)
      configuration.delivery.retry.maximumAttempts = 1
      let runtime = try makeRuntime(
        configuration: configuration,
        transport: transport.transport
      )

      runtime.client.recordNavigation(.push, route: "settings")
      let result = await runtime.forceFlush(timeout: .seconds(2))

      #expect(result.traces.status == .failed)
      #expect(runtime.diagnostics.traces.nonRetryableFailures == 1)
      _ = await runtime.shutdown()
    }
  }

  @Suite("Persistence")
  struct PersistenceTests {
    @Test("recovers persisted batches on relaunch and never persists authorization")
    func relaunchRecovery() async throws {
      let clock = TestRuntimeClock()
      let fileSystem = TestRuntimeFileSystem()
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let persistenceConfiguration = TelemetryPersistenceConfiguration(
        directory: URL(fileURLWithPath: "/runtime-spool"),
        maximumBytes: 64 * 1_024
      )
      let firstStore = try RuntimePersistenceStore(
        configuration: persistenceConfiguration,
        fileSystem: fileSystem.fileSystem,
        diagnostics: diagnostics
      )
      let firstEngine = makeDeliveryEngine(
        clock: clock,
        transport: ScriptedTransport([]).transport,
        persistence: firstStore
      )
      await firstEngine.setCondition(.unavailable)
      var request = testRequest(body: Data("safe-body".utf8))
      request.setValue("Bearer must-not-persist", forHTTPHeaderField: "Authorization")
      #expect(await firstEngine.enqueue(request: request, signal: .traces))
      #expect(fileSystem.fileContents.none { $0.containsData(Data("must-not-persist".utf8)) })
      await firstEngine.shutdown(retainPersisted: true)

      let transport = ScriptedTransport([.status(202)])
      let secondStore = try RuntimePersistenceStore(
        configuration: persistenceConfiguration,
        fileSystem: fileSystem.fileSystem,
        diagnostics: diagnostics
      )
      let secondEngine = makeDeliveryEngine(
        clock: clock,
        transport: transport.transport,
        persistence: secondStore
      )
      await secondEngine.start()
      try await eventually { await transport.requestCount == 1 }
      try await eventually { diagnostics.snapshot().persistedItems == 0 }
    }

    @Test("removes corrupt and expired files while retaining bounded storage posture")
    func corruptionAndAgeRecovery() throws {
      let fileSystem = TestRuntimeFileSystem()
      let directory = URL(fileURLWithPath: "/runtime-spool")
      fileSystem.insert(
        Data("not-json".utf8),
        at: directory.appendingPathComponent("corrupt.json")
      )
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let configuration = TelemetryPersistenceConfiguration(
        directory: directory,
        maximumBytes: 4 * 1_024,
        maximumAge: .seconds(10),
        fileProtection: .complete
      )
      let store = try RuntimePersistenceStore(
        configuration: configuration,
        fileSystem: fileSystem.fileSystem,
        diagnostics: diagnostics
      )

      #expect(store.load(now: Date()).isEmpty)
      #expect(diagnostics.snapshot().recoveredCorruptFiles == 1)
      #expect(fileSystem.atomicWriteCount == 0)
      #expect(fileSystem.protectedURLs.contains(directory))
      #expect(fileSystem.backupExcludedURLs.contains(directory))

      let old = PendingOTLPBatch(
        id: UUID(),
        signal: .logs,
        createdAt: Date(timeIntervalSince1970: 1),
        attempt: 0,
        request: testRequest()
      )
      #expect(store.save(old).saved)
      let relaunched = try RuntimePersistenceStore(
        configuration: configuration,
        fileSystem: fileSystem.fileSystem,
        diagnostics: diagnostics
      )
      #expect(relaunched.load(now: Date(timeIntervalSince1970: 20)).isEmpty)

      let oversized = PendingOTLPBatch(
        id: UUID(),
        signal: .metrics,
        createdAt: Date(timeIntervalSince1970: 20),
        attempt: 0,
        request: testRequest(body: Data(repeating: 1, count: 8 * 1_024))
      )
      #expect(store.save(oversized).saved == false)
    }

    @Test("sanitizes raw spans before the persistence boundary")
    func privacyBeforeStorage() async throws {
      let fileSystem = TestRuntimeFileSystem()
      var configuration = runtimeConfiguration(
        signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false)
      )
      configuration.traces = .init(maximumQueueSize: 1, maximumBatchSize: 1)
      configuration.persistence = .init(
        directory: URL(fileURLWithPath: "/runtime-spool"),
        maximumBytes: 64 * 1_024
      )
      let runtime = try makeRuntime(
        configuration: configuration,
        transport: ScriptedTransport([]).transport,
        dependencies: .init(
          clock: .live,
          fileSystem: fileSystem.fileSystem,
          makeID: UUID.init
        )
      )
      await runtime.setExportCondition(.unavailable)

      let span = runtime.client.tracer.spanBuilder(spanName: runtimeSentinelSecret)
        .setAttribute(key: "secret", value: runtimeSentinelSecret)
        .startSpan()
      span.end()
      try await eventually { runtime.diagnostics.persistedItems == 1 }

      let decodedBodies = try fileSystem.fileContents.compactMap(persistedBody)
      #expect(!decodedBodies.isEmpty)
      #expect(decodedBodies.none { $0.containsData(Data(runtimeSentinelSecret.utf8)) })
      _ = await runtime.shutdown(timeout: .milliseconds(50))
    }
  }

  @Suite("Lifecycle")
  struct LifecycleTests {
    @Test("diagnostics are structured and suppress recursive emission")
    func nonRecursiveDiagnostics() {
      let holder = DiagnosticsHolder()
      let events = DiagnosticCapture()
      let state = RuntimeDiagnosticsState { event in
        events.append(event)
        holder.state?.recordAttempt(signal: .traces)
      }
      holder.state = state

      state.recordDrop(signal: .traces)

      #expect(events.count == 1)
      #expect(state.snapshot().traces.droppedItems == 1)
      #expect(state.snapshot().traces.attempts == 1)
    }

    @Test("shutdown is idempotent across all signals")
    func idempotentShutdown() async throws {
      let runtime = try makeRuntime()
      let first = await runtime.shutdown(timeout: .seconds(1))
      let second = await runtime.shutdown(timeout: .seconds(1))

      #expect(first == second)
      #expect(first.operation == .shutdown)
    }
  }
}

private func runtimeConfiguration(
  signals: TelemetrySignalConfiguration = .init()
) -> TelemetryRuntime.Configuration {
  .init(
    serviceName: "test-suite",
    serviceVersion: "1.2.3",
    endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
    samplingRatio: 1,
    policy: testPolicy(signals: signals),
    traces: .init(scheduledDelay: .milliseconds(10)),
    logs: .init(scheduledDelay: .milliseconds(10)),
    metricExportInterval: .seconds(3_600)
  )
}

private func makeRuntime(
  endpoints: OTLPEndpoints? = nil,
  configuration: TelemetryRuntime.Configuration? = nil,
  transport: TelemetryHTTPTransport = ScriptedTransport([]).transport,
  dependencies: TelemetryRuntimeDependencies = .live
) throws -> TelemetryRuntime {
  var resolved = configuration ?? runtimeConfiguration()
  if let endpoints {
    resolved.endpoints = endpoints
  }
  return try TelemetryRuntime(
    configuration: resolved,
    transport: transport,
    authenticator: .none,
    diagnosticHandler: nil,
    dependencies: dependencies
  )
}

private func makeDeliveryEngine(
  clock: TestRuntimeClock,
  transport: TelemetryHTTPTransport,
  authenticator: TelemetryRequestAuthenticator = .none,
  delivery: TelemetryDeliveryConfiguration = .init(),
  persistence: RuntimePersistenceStore? = nil
) -> RuntimeDeliveryEngine {
  RuntimeDeliveryEngine(
    configuration: delivery,
    transport: transport,
    authenticator: authenticator,
    diagnostics: RuntimeDiagnosticsState(handler: nil),
    dependencies: .init(
      clock: clock.runtimeClock,
      fileSystem: .live,
      makeID: UUID.init
    ),
    persistence: persistence
  )
}

private func testRequest(body: Data = Data("body".utf8)) -> URLRequest {
  var request = URLRequest(url: URL(string: "https://gateway.example.test/v1/traces")!)
  request.httpMethod = "POST"
  request.httpBody = body
  request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
  return request
}

private func eventually(
  timeout: Duration = .seconds(2),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !(await condition()) {
    guard clock.now < deadline else {
      Issue.record("Condition did not become true before the deadline")
      return
    }
    try await Task.sleep(for: .milliseconds(1))
  }
}

private func wait(
  for semaphore: DispatchSemaphore,
  timeout: TimeInterval
) async -> DispatchTimeoutResult {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
    }
  }
}

private final class BatchCapture<Value: Equatable & Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [[Value]] = []

  var values: [[Value]] {
    lock.withLock { storage }
  }

  func append(_ values: [Value]) {
    lock.withLock {
      storage.append(values)
    }
  }
}

private final class DiagnosticsHolder: @unchecked Sendable {
  var state: RuntimeDiagnosticsState?
}

private final class DiagnosticCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [TelemetryRuntimeDiagnosticEvent] = []

  var count: Int {
    lock.withLock { events.count }
  }

  func append(_ event: TelemetryRuntimeDiagnosticEvent) {
    lock.withLock {
      events.append(event)
    }
  }
}

private final class TestRuntimeClock: @unchecked Sendable {
  private struct Sleeper {
    var deadline: Date
    var continuation: CheckedContinuation<Void, any Error>
  }

  private let lock = NSLock()
  private var now = Date(timeIntervalSince1970: 1_000)
  private var sleepers: [UUID: Sleeper] = [:]
  private let randomUnit: Double

  init(randomUnit: Double = 0.5) {
    self.randomUnit = randomUnit
  }

  var runtimeClock: TelemetryRuntimeClock {
    TelemetryRuntimeClock(
      now: { [weak self] in
        guard let self else { return Date(timeIntervalSince1970: 0) }
        return self.lock.withLock { self.now }
      },
      sleep: { [weak self] duration in
        guard let self else { return }
        try await self.sleep(for: duration)
      },
      randomUnit: { [randomUnit] in randomUnit }
    )
  }

  var pendingSleeps: Int {
    lock.withLock { sleepers.count }
  }

  var pendingDurations: [Duration] {
    lock.withLock {
      sleepers.values.map {
        .runtimeSeconds(max(0, $0.deadline.timeIntervalSince(now)))
      }
    }
  }

  func advance(by duration: Duration) {
    let continuations = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
      now = now.addingTimeInterval(duration.runtimeSeconds)
      let ready = sleepers.filter { $0.value.deadline <= now }
      for id in ready.keys {
        sleepers.removeValue(forKey: id)
      }
      return ready.values.map(\.continuation)
    }
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func sleep(for duration: Duration) async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        let resumeImmediately = lock.withLock {
          let deadline = now.addingTimeInterval(duration.runtimeSeconds)
          guard deadline > now else { return true }
          sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
          return false
        }
        if resumeImmediately {
          continuation.resume()
        }
      }
    } onCancel: {
      let continuation = self.lock.withLock {
        self.sleepers.removeValue(forKey: id)?.continuation
      }
      continuation?.resume(throwing: CancellationError())
    }
  }
}

private actor ScriptedTransport {
  enum Step: Sendable {
    case status(Int)
    case suspend
  }

  private var steps: [Step]
  private var requests: [URLRequest] = []

  init(_ steps: [Step]) {
    self.steps = steps
  }

  nonisolated var transport: TelemetryHTTPTransport {
    TelemetryHTTPTransport { [weak self] request in
      guard let self else {
        throw CancellationError()
      }
      return try await self.send(request)
    }
  }

  var requestCount: Int {
    requests.count
  }

  private func send(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
    requests.append(request)
    let step = steps.isEmpty ? .suspend : steps.removeFirst()
    switch step {
    case .status(let status):
      return TelemetryHTTPResponse(statusCode: status)
    case .suspend:
      try await Task.sleep(for: .seconds(30))
      throw CancellationError()
    }
  }
}

private actor AuthRecorder {
  private(set) var headers: [String] = []

  func authorize(_ original: URLRequest) -> URLRequest {
    var request = original
    let value = "Bearer token-\(headers.count + 1)"
    headers.append(value)
    request.setValue(value, forHTTPHeaderField: "Authorization")
    return request
  }
}

private final class TestRuntimeFileSystem: @unchecked Sendable {
  private let lock = NSLock()
  private var files: [URL: Data] = [:]
  private var directories: Set<URL> = []
  private(set) var atomicWriteCount = 0
  private(set) var protectedURLs: Set<URL> = []
  private(set) var backupExcludedURLs: Set<URL> = []

  var fileSystem: TelemetryRuntimeFileSystem {
    TelemetryRuntimeFileSystem(
      createDirectory: { [weak self] url in
        _ = self?.lock.withLock {
          self?.directories.insert(url)
        }
      },
      listFiles: { [weak self] directory in
        self?.lock.withLock {
          self?.files.keys.filter {
            $0.deletingLastPathComponent().standardizedFileURL.path
              == directory.standardizedFileURL.path
          }
        } ?? []
      },
      read: { [weak self] url in
        guard let data = self?.lock.withLock({ self?.files[url] }) else {
          throw CocoaError(.fileReadNoSuchFile)
        }
        return data
      },
      writeAtomically: { [weak self] data, url in
        self?.lock.withLock {
          self?.files[url] = data
          self?.atomicWriteCount += 1
        }
      },
      remove: { [weak self] url in
        _ = self?.lock.withLock {
          self?.files.removeValue(forKey: url)
        }
      },
      applyProtection: { [weak self] url, _ in
        _ = self?.lock.withLock {
          self?.protectedURLs.insert(url)
        }
      },
      excludeFromBackup: { [weak self] url in
        _ = self?.lock.withLock {
          self?.backupExcludedURLs.insert(url)
        }
      }
    )
  }

  var fileContents: [Data] {
    lock.withLock { Array(files.values) }
  }

  func insert(_ data: Data, at url: URL) {
    lock.withLock {
      files[url] = data
    }
  }
}

private func persistedBody(_ data: Data) throws -> Data? {
  guard
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let body = object["body"] as? String
  else {
    return nil
  }
  return Data(base64Encoded: body)
}

extension Array where Element == Data {
  fileprivate func none(_ predicate: (Data) -> Bool) -> Bool {
    !contains(where: predicate)
  }
}

extension Data {
  fileprivate func containsData(_ other: Data) -> Bool {
    range(of: other) != nil
  }
}
