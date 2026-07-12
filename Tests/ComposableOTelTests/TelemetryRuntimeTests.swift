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

    @Test("dropNewest preserves queued items and records the rejected item")
    func dropNewestOverflow() async throws {
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let capture = BatchCapture<Int>()
      let firstExportStarted = DispatchSemaphore(value: 0)
      let releaseFirstExport = DispatchSemaphore(value: 0)
      let queue = RuntimeBatchQueue<Int>(
        configuration: .init(
          maximumQueueSize: 2,
          maximumBatchSize: 2,
          scheduledDelay: .seconds(60),
          overflowPolicy: .dropNewest
        ),
        signal: .traces,
        diagnostics: diagnostics,
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

      #expect(capture.values == [[1, 2], [3, 4]])
      #expect(diagnostics.snapshot().traces.droppedItems == 1)
      await queue.shutdown()
    }

    @Test("forceFlush drains every batch and reports exporter failure drops")
    func forceFlushAndExporterFailure() async {
      let successfulCapture = BatchCapture<Int>()
      let successfulQueue = RuntimeBatchQueue<Int>(
        configuration: .init(
          maximumQueueSize: 8,
          maximumBatchSize: 2,
          scheduledDelay: .seconds(60)
        ),
        signal: .metrics,
        diagnostics: RuntimeDiagnosticsState(handler: nil),
        clock: .live,
        export: { values, _ in
          successfulCapture.append(values)
          return true
        },
        shutdownExporter: { _ in }
      )
      for value in 1...5 {
        successfulQueue.offer(value)
      }
      await successfulQueue.forceFlush()
      #expect(successfulCapture.values == [[1, 2], [3, 4], [5]])
      await successfulQueue.shutdown()

      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let failingQueue = RuntimeBatchQueue<Int>(
        configuration: .init(maximumQueueSize: 1, maximumBatchSize: 1),
        signal: .logs,
        diagnostics: diagnostics,
        clock: .live,
        export: { _, _ in false },
        shutdownExporter: { _ in }
      )
      failingQueue.offer(1)
      await failingQueue.forceFlush()
      #expect(diagnostics.snapshot().logs.droppedItems == 1)
      await failingQueue.shutdown()
    }

    @Test("concurrent producers preserve bounded accounting without duplication")
    func concurrentOfferStress() async {
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let capture = BatchCapture<Int>()
      let queue = RuntimeBatchQueue<Int>(
        configuration: .init(
          maximumQueueSize: 64,
          maximumBatchSize: 16,
          scheduledDelay: .seconds(60),
          overflowPolicy: .dropOldest
        ),
        signal: .traces,
        diagnostics: diagnostics,
        clock: .live,
        export: { values, _ in
          capture.append(values)
          return true
        },
        shutdownExporter: { _ in }
      )

      await withTaskGroup(of: Void.self) { group in
        for producer in 0..<8 {
          group.addTask {
            for offset in 0..<100 {
              queue.offer(producer * 100 + offset)
            }
          }
        }
      }
      async let firstFlush: Void = queue.forceFlush()
      async let secondFlush: Void = queue.forceFlush()
      _ = await (firstFlush, secondFlush)

      let exported = capture.values.flatMap { $0 }
      let dropped = diagnostics.snapshot().traces.droppedItems
      #expect(exported.count + dropped == 800)
      #expect(Set(exported).count == exported.count)
      #expect(queue.pendingCount == 0)
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

    @Test("retry exhaustion honors the capped backoff and records every failure")
    func retryExhaustionAndBackoffCap() async throws {
      let clock = TestRuntimeClock()
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let transport = ScriptedTransport([.status(503), .status(503), .status(503)])
      let engine = makeDeliveryEngine(
        clock: clock,
        transport: transport.transport,
        delivery: .init(
          requestTimeout: .seconds(20),
          retry: .init(
            maximumAttempts: 3,
            initialBackoff: .seconds(2),
            maximumBackoff: .seconds(3),
            jitterRatio: 0
          )
        ),
        diagnostics: diagnostics
      )

      await engine.start()
      #expect(await engine.enqueue(request: testRequest(), signal: .traces))
      try await eventually { clock.pendingDurations.contains(.seconds(2)) }
      clock.advance(by: .seconds(2))
      try await eventually { clock.pendingDurations.contains(.seconds(3)) }
      clock.advance(by: .seconds(3))
      try await eventually { await engine.pendingBySignal()[.traces] == 0 }

      let snapshot = diagnostics.snapshot().traces
      #expect(await transport.requestCount == 3)
      #expect(snapshot.retryableFailures == 3)
      #expect(snapshot.droppedItems == 1)
    }

    @Test("transport and authenticator errors follow explicit retry classification")
    func errorClassification() async throws {
      let retryClock = TestRuntimeClock()
      let retryDiagnostics = RuntimeDiagnosticsState(handler: nil)
      let retryTransport = ScriptedTransport([
        .urlError(.networkConnectionLost), .status(202),
      ])
      let retryEngine = makeDeliveryEngine(
        clock: retryClock,
        transport: retryTransport.transport,
        delivery: .init(
          requestTimeout: .seconds(20),
          retry: .init(
            maximumAttempts: 2,
            initialBackoff: .seconds(1),
            maximumBackoff: .seconds(1),
            jitterRatio: 0
          )
        ),
        diagnostics: retryDiagnostics
      )
      await retryEngine.start()
      #expect(await retryEngine.enqueue(request: testRequest(), signal: .logs))
      try await eventually("retryable transport entered backoff") {
        retryClock.pendingDurations.contains(.seconds(1))
      }
      retryClock.advance(by: .seconds(1))
      try await eventually("retryable transport eventually succeeded") {
        await retryEngine.pendingBySignal()[.logs] == 0
      }
      #expect(retryDiagnostics.snapshot().logs.retryableFailures == 1)
      #expect(retryDiagnostics.snapshot().logs.successes == 1)

      let failureClock = TestRuntimeClock()
      let failureDiagnostics = RuntimeDiagnosticsState(handler: nil)
      let failureTransport = ScriptedTransport([.classifiedError(retryable: false)])
      let failureEngine = makeDeliveryEngine(
        clock: failureClock,
        transport: failureTransport.transport,
        delivery: .init(retry: .init(maximumAttempts: 3)),
        diagnostics: failureDiagnostics
      )
      await failureEngine.start()
      #expect(await failureEngine.enqueue(request: testRequest(), signal: .metrics))
      try await eventually("custom non-retryable failure was classified") {
        failureDiagnostics.snapshot().metrics.nonRetryableFailures == 1
      }
      #expect(await failureTransport.requestCount == 1)
      #expect(failureDiagnostics.snapshot().metrics.nonRetryableFailures == 1)
      #expect(await failureEngine.pendingBySignal()[.metrics] == 0)

      let authClock = TestRuntimeClock()
      let authDiagnostics = RuntimeDiagnosticsState(handler: nil)
      let authEngine = makeDeliveryEngine(
        clock: authClock,
        transport: ScriptedTransport([.status(202)]).transport,
        authenticator: .init { _ in throw RuntimeTestError.unclassified },
        delivery: .init(retry: .init(maximumAttempts: 3)),
        diagnostics: authDiagnostics
      )
      await authEngine.start()
      #expect(await authEngine.enqueue(request: testRequest(), signal: .traces))
      try await eventually("authenticator failure was classified") {
        authDiagnostics.snapshot().traces.nonRetryableFailures == 1
      }
      #expect(authDiagnostics.snapshot().traces.nonRetryableFailures == 1)
      #expect(authDiagnostics.snapshot().traces.droppedItems == 1)
      #expect(await authEngine.pendingBySignal()[.traces] == 0)
    }

    @Test("delivery overflow policies and shutdown keep exact drop accounting")
    func deliveryOverflowAndShutdown() async {
      let clock = TestRuntimeClock()
      let transport = ScriptedTransport([])
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let engine = makeDeliveryEngine(
        clock: clock,
        transport: transport.transport,
        delivery: .init(maximumPendingBatches: 2, overflowPolicy: .dropNewest),
        diagnostics: diagnostics
      )
      await engine.setCondition(.unavailable)
      #expect(await engine.enqueue(request: testRequest(), signal: .traces))
      #expect(await engine.enqueue(request: testRequest(), signal: .logs))
      #expect(await engine.enqueue(request: testRequest(), signal: .metrics) == false)
      await engine.shutdown(retainPersisted: false)

      #expect(diagnostics.snapshot().metrics.droppedItems == 1)
      #expect(diagnostics.snapshot().traces.droppedItems == 1)
      #expect(diagnostics.snapshot().logs.droppedItems == 1)
      #expect(diagnostics.snapshot().traces.queueDepth == 0)
      #expect(diagnostics.snapshot().logs.queueDepth == 0)
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
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let engine = makeDeliveryEngine(
        clock: clock,
        transport: transport.transport,
        diagnostics: diagnostics
      )
      await engine.setCondition(.unavailable)
      #expect(await engine.enqueue(request: testRequest(), signal: .logs))

      let flush = Task {
        await engine.flush(timeout: .seconds(5))
      }
      try await eventually { clock.pendingSleeps > 0 }
      clock.advance(by: .seconds(5))
      #expect(await flush.value == false)
      #expect(await transport.requestCount == 0)
      #expect(diagnostics.snapshot().timedOutFlushes == 1)
    }

    @Test("successful flush records completion time and disabled signal results")
    func successfulFlushDiagnosticsAndDisabledSignals() async throws {
      let clock = TestRuntimeClock()
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let transport = ScriptedTransport([.status(202)])
      let engine = makeDeliveryEngine(
        clock: clock,
        transport: transport.transport,
        diagnostics: diagnostics
      )
      await engine.start()
      #expect(await engine.enqueue(request: testRequest(), signal: .traces))
      try await eventually { await engine.pendingBySignal()[.traces] == 0 }
      #expect(await engine.flush(timeout: .seconds(1)))
      #expect(diagnostics.snapshot().completedFlushes == 1)
      #expect(diagnostics.snapshot().traces.lastSuccess == clock.currentDate)

      let runtime = try makeRuntime(
        configuration: runtimeConfiguration(
          signals: .init(tracesEnabled: false, metricsEnabled: false, logsEnabled: false)
        )
      )
      let result = await runtime.forceFlush(timeout: .seconds(1))
      #expect(result.traces.status == .disabled)
      #expect(result.metrics.status == .disabled)
      #expect(result.logs.status == .disabled)
      _ = await runtime.shutdown()
    }

    @Test("one failed signal does not change another signal's successful result")
    func crossSignalFailureIsolation() async throws {
      let transport = TelemetryHTTPTransport { request in
        let status = request.url?.path.hasSuffix("/v1/traces") == true ? 400 : 202
        return TelemetryHTTPResponse(statusCode: status)
      }
      var configuration = runtimeConfiguration(
        signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
      )
      configuration.traces = .init(maximumQueueSize: 1, maximumBatchSize: 1)
      configuration.logs = .init(maximumQueueSize: 1, maximumBatchSize: 1)
      configuration.delivery.retry.maximumAttempts = 1
      let runtime = try makeRuntime(configuration: configuration, transport: transport)

      runtime.client.recordNavigation(.push, route: "settings")
      let result = await runtime.forceFlush(timeout: .seconds(2))

      #expect(result.traces.status == .failed)
      #expect(result.logs.status == .success)
      #expect(runtime.diagnostics.traces.nonRetryableFailures == 1)
      #expect(runtime.diagnostics.logs.successes == 1)
      _ = await runtime.shutdown()
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
      #expect(fileSystem.fileContents.none { $0.containsData(Data("Authorization".utf8)) })
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

    @Test("rejects unsupported records, write failures, and unprotected spool files")
    func persistenceFailureModes() throws {
      let fileSystem = TestRuntimeFileSystem()
      let directory = URL(fileURLWithPath: "/runtime-spool")
      let unsupported: [String: Any] = [
        "version": 0,
        "id": UUID().uuidString,
        "signal": "traces",
        "createdAt": 1_000_000,
        "attempt": 0,
        "url": "https://gateway.example.test/v1/traces",
        "method": "POST",
        "headers": ["Content-Type": "application/x-protobuf"],
        "body": Data("body".utf8).base64EncodedString(),
      ]
      fileSystem.insert(
        try JSONSerialization.data(withJSONObject: unsupported),
        at: directory.appendingPathComponent("unsupported.json")
      )
      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let configuration = TelemetryPersistenceConfiguration(
        directory: directory,
        maximumBytes: 64 * 1_024,
        fileProtection: .complete
      )
      let store = try RuntimePersistenceStore(
        configuration: configuration,
        fileSystem: fileSystem.fileSystem,
        diagnostics: diagnostics
      )

      #expect(store.load(now: Date(timeIntervalSince1970: 1_000)).isEmpty)
      #expect(diagnostics.snapshot().recoveredCorruptFiles == 1)

      let batch = PendingOTLPBatch(
        id: UUID(),
        signal: .logs,
        createdAt: Date(timeIntervalSince1970: 1_000),
        attempt: 0,
        request: testRequest()
      )
      fileSystem.failWrites = true
      #expect(store.save(batch).saved == false)
      fileSystem.failWrites = false
      #expect(store.save(batch).saved)
      #expect(fileSystem.protectedURLs.contains { $0.pathExtension == "json" })
      #expect(diagnostics.snapshot().persistedBytes == fileSystem.fileContents.first?.count)
    }

    @Test("load evicts the oldest valid records beyond the byte budget")
    func loadEvictsOldest() throws {
      let fileSystem = TestRuntimeFileSystem()
      let directory = URL(fileURLWithPath: "/runtime-spool")
      let initialDiagnostics = RuntimeDiagnosticsState(handler: nil)
      let initial = try RuntimePersistenceStore(
        configuration: .init(
          directory: directory,
          maximumBytes: 64 * 1_024
        ),
        fileSystem: fileSystem.fileSystem,
        diagnostics: initialDiagnostics
      )
      let first = PendingOTLPBatch(
        id: UUID(),
        signal: .traces,
        createdAt: Date(timeIntervalSince1970: 1),
        attempt: 0,
        request: testRequest(body: Data(repeating: 1, count: 512))
      )
      let second = PendingOTLPBatch(
        id: UUID(),
        signal: .logs,
        createdAt: Date(timeIntervalSince1970: 2),
        attempt: 0,
        request: testRequest(body: Data(repeating: 2, count: 512))
      )
      #expect(initial.save(first).saved)
      #expect(initial.save(second).saved)
      let totalBytes = initialDiagnostics.snapshot().persistedBytes

      let diagnostics = RuntimeDiagnosticsState(handler: nil)
      let bounded = try RuntimePersistenceStore(
        configuration: .init(
          directory: directory,
          maximumBytes: totalBytes - 1
        ),
        fileSystem: fileSystem.fileSystem,
        diagnostics: diagnostics
      )
      let loaded = bounded.load(now: Date(timeIntervalSince1970: 3))
      #expect(loaded.map(\.id) == [second.id])
      #expect(diagnostics.snapshot().traces.droppedItems == 1)
      #expect(diagnostics.snapshot().persistedItems == 1)
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

    @Test("background lifecycle uses the tighter host deadline")
    func backgroundUsesRemainingTime() async throws {
      let clock = TestRuntimeClock()
      let transport = ScriptedTransport([.status(202)])
      var configuration = runtimeConfiguration(
        signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false)
      )
      configuration.traces = .init(maximumQueueSize: 1, maximumBatchSize: 1)
      configuration.backgroundFlushTimeout = .seconds(10)
      let runtime = try makeRuntime(
        configuration: configuration,
        transport: transport.transport,
        dependencies: .init(
          clock: clock.runtimeClock,
          fileSystem: .live,
          makeID: UUID.init
        )
      )
      await runtime.setExportCondition(.unavailable)
      runtime.client.recordNavigation(.push, route: "settings")
      try await eventually("runtime queued a trace before backgrounding") {
        runtime.diagnostics.traces.queueDepth == 1
      }

      let background = Task {
        await runtime.applicationDidEnterBackground(remainingTime: .seconds(2))
      }
      try await eventually("background flush started its deadline") {
        clock.pendingSleeps > 0
      }
      clock.advance(by: .seconds(2))
      let result = await background.value

      #expect(result.operation == .background)
      #expect(result.traces.status == .timedOut)
      #expect(runtime.diagnostics.timedOutFlushes == 1)

      await runtime.setExportCondition(.available)
      try await eventually("delivery resumed after the background timeout") {
        runtime.diagnostics.traces.queueDepth == 0
      }
      _ = await runtime.shutdown(timeout: .seconds(1))
    }

    @Test("concurrent shutdown calls coalesce and later activation stays stopped")
    func concurrentShutdown() async throws {
      let runtime = try makeRuntime()
      let results = await withTaskGroup(
        of: TelemetryRuntimeOperationResult.self,
        returning: [TelemetryRuntimeOperationResult].self
      ) { group in
        for _ in 0..<16 {
          group.addTask {
            await runtime.shutdown(timeout: .seconds(1))
          }
        }
        var results: [TelemetryRuntimeOperationResult] = []
        for await result in group {
          results.append(result)
        }
        return results
      }

      let first = try #require(results.first)
      #expect(results.allSatisfy { $0 == first })
      #expect(runtime.diagnostics.completedFlushes == 1)
      await runtime.applicationDidBecomeActive()
      #expect(await runtime.shutdown() == first)
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
  persistence: RuntimePersistenceStore? = nil,
  diagnostics: RuntimeDiagnosticsState = RuntimeDiagnosticsState(handler: nil)
) -> RuntimeDeliveryEngine {
  RuntimeDeliveryEngine(
    configuration: delivery,
    transport: transport,
    authenticator: authenticator,
    diagnostics: diagnostics,
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
  _ description: String = "Condition",
  timeout: Duration = .seconds(10),
  condition: @escaping @Sendable () async -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !(await condition()) {
    guard clock.now < deadline else {
      Issue.record("\(description) did not become true before the deadline")
      throw RuntimeTestError.eventuallyTimedOut
    }
    try await Task.sleep(for: .milliseconds(1))
  }
}

private enum RuntimeTestError: Error, TelemetryRetryClassifyingError {
  case eventuallyTimedOut
  case unclassified
  case classified(Bool)

  var telemetryRetryable: Bool {
    switch self {
    case .classified(let retryable):
      retryable
    case .eventuallyTimedOut, .unclassified:
      false
    }
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
        Duration.runtimeSeconds(max(0, $0.deadline.timeIntervalSince(now)))
      }
    }
  }

  var currentDate: Date {
    lock.withLock { now }
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
    case urlError(URLError.Code)
    case classifiedError(retryable: Bool)
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

  var authorizationHeaders: [String] {
    requests.compactMap { $0.value(forHTTPHeaderField: "Authorization") }
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
    case .urlError(let code):
      throw URLError(code)
    case .classifiedError(let retryable):
      throw RuntimeTestError.classified(retryable)
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
  private var writes = 0
  private var protected = Set<URL>()
  private var backupExcluded = Set<URL>()
  private var writesFail = false

  var failWrites: Bool {
    get { lock.withLock { writesFail } }
    set { lock.withLock { writesFail = newValue } }
  }

  var atomicWriteCount: Int {
    lock.withLock { writes }
  }

  var protectedURLs: Set<URL> {
    lock.withLock { protected }
  }

  var backupExcludedURLs: Set<URL> {
    lock.withLock { backupExcluded }
  }

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
        guard let self else { return }
        try self.lock.withLock {
          if self.writesFail {
            throw CocoaError(.fileWriteUnknown)
          }
          self.files[url] = data
          self.writes += 1
        }
      },
      remove: { [weak self] url in
        _ = self?.lock.withLock {
          self?.files.removeValue(forKey: url)
        }
      },
      applyProtection: { [weak self] url, _ in
        _ = self?.lock.withLock {
          self?.protected.insert(url)
        }
      },
      excludeFromBackup: { [weak self] url in
        _ = self?.lock.withLock {
          self?.backupExcluded.insert(url)
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
