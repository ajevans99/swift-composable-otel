import Foundation
import OpenTelemetryProtocolExporterHttp

/// Allows a host transport or authenticator error to opt into bounded retry.
public protocol TelemetryRetryClassifyingError: Error {
  var telemetryRetryable: Bool { get }
}

struct RuntimeDiscardOutcome: Sendable {
  var discardedBySignal: [TelemetryRuntimeSignal: Int]
  var failedBySignal: [TelemetryRuntimeSignal: Int]
  var failedPersistedFiles: Int
  var remainingPersistedItems: Int
}

actor RuntimeDeliveryEngine {
  private let configuration: TelemetryDeliveryConfiguration
  private let transport: TelemetryHTTPTransport
  private let authenticator: TelemetryRequestAuthenticator
  private let diagnostics: RuntimeDiagnosticsState
  private let clock: TelemetryRuntimeClock
  private let makeID: @Sendable () -> UUID
  private let persistence: RuntimePersistenceStore?

  private var queue: [PendingOTLPBatch]
  private var inFlight: PendingOTLPBatch?
  private var condition = TelemetryExportCondition.available
  private var worker: Task<Void, Never>?
  private var isShutdown = false
  private var discardOutcome: RuntimeDiscardOutcome?

  init(
    configuration: TelemetryDeliveryConfiguration,
    transport: TelemetryHTTPTransport,
    authenticator: TelemetryRequestAuthenticator,
    diagnostics: RuntimeDiagnosticsState,
    dependencies: TelemetryRuntimeDependencies,
    persistence: RuntimePersistenceStore?
  ) {
    self.configuration = configuration
    self.transport = transport
    self.authenticator = authenticator
    self.diagnostics = diagnostics
    clock = dependencies.clock
    makeID = dependencies.makeID
    self.persistence = persistence
    queue = persistence?.load(now: dependencies.clock.now()) ?? []

    let oversized = queue.filter {
      !Self.accepts(
        request: $0.request,
        maximumEncodedRequestBytes: configuration.maximumEncodedRequestBytes
      )
    }
    if !oversized.isEmpty {
      let oversizedIDs = Set(oversized.map(\.id))
      queue.removeAll { oversizedIDs.contains($0.id) }
      for batch in oversized {
        persistence?.remove(batch.id)
        diagnostics.recordEncodedRequestTooLarge(signal: batch.signal)
        diagnostics.recordDrop(signal: batch.signal)
      }
    }

    if queue.count > configuration.maximumPendingBatches {
      let overflow = queue.count - configuration.maximumPendingBatches
      let removed: [PendingOTLPBatch]
      switch configuration.overflowPolicy {
      case .dropNewest:
        removed = Array(queue.suffix(overflow))
        queue.removeLast(overflow)
      case .dropOldest:
        removed = Array(queue.prefix(overflow))
        queue.removeFirst(overflow)
      }
      for batch in removed {
        persistence?.remove(batch.id)
        diagnostics.recordDrop(signal: batch.signal)
      }
    }
    for batch in queue {
      diagnostics.adjustQueueDepth(by: 1, signal: batch.signal)
    }
  }

  func start() {
    startWorkerIfNeeded()
  }

  @discardableResult
  func enqueue(request: URLRequest, signal: TelemetryRuntimeSignal) -> Bool {
    guard !isShutdown else {
      diagnostics.recordDrop(signal: signal)
      return false
    }
    guard
      Self.accepts(
        request: request,
        maximumEncodedRequestBytes: configuration.maximumEncodedRequestBytes
      )
    else {
      diagnostics.recordEncodedRequestTooLarge(signal: signal)
      diagnostics.recordDrop(signal: signal)
      return false
    }

    let pendingCount = queue.count + (inFlight == nil ? 0 : 1)
    if pendingCount >= configuration.maximumPendingBatches {
      switch configuration.overflowPolicy {
      case .dropNewest:
        diagnostics.recordDrop(signal: signal)
        return false
      case .dropOldest:
        guard !queue.isEmpty else {
          diagnostics.recordDrop(signal: signal)
          return false
        }
        let removed = queue.removeFirst()
        persistence?.remove(removed.id)
        diagnostics.adjustQueueDepth(by: -1, signal: removed.signal)
        diagnostics.recordDrop(signal: removed.signal)
      }
    }

    let batch = PendingOTLPBatch(
      id: makeID(),
      signal: signal,
      createdAt: clock.now(),
      attempt: 0,
      request: request
    )
    if let persistence, !persistence.save(batch).saved {
      diagnostics.recordDrop(signal: signal)
      return false
    }
    queue.append(batch)
    diagnostics.adjustQueueDepth(by: 1, signal: signal)
    startWorkerIfNeeded()
    return true
  }

  func setCondition(_ condition: TelemetryExportCondition) {
    self.condition = condition
    startWorkerIfNeeded()
  }

  func flush(timeout: Duration) async -> Bool {
    startWorkerIfNeeded()
    let deadline = clock.now().addingTimeInterval(timeout.runtimeSeconds)
    while pendingCount > 0 {
      let remaining = deadline.timeIntervalSince(clock.now())
      guard remaining > 0 else {
        diagnostics.recordFlush(completed: false)
        return false
      }
      do {
        try await clock.sleep(.runtimeSeconds(min(remaining, 0.01)))
      } catch {
        diagnostics.recordFlush(completed: false)
        return false
      }
    }
    diagnostics.recordFlush(completed: true)
    return true
  }

  func shutdown(retainPersisted: Bool) {
    guard !isShutdown else { return }
    isShutdown = true
    worker?.cancel()
    worker = nil

    guard !retainPersisted else { return }
    let pending = queue + [inFlight].compactMap { $0 }
    queue.removeAll()
    inFlight = nil
    for batch in pending {
      persistence?.remove(batch.id)
      diagnostics.adjustQueueDepth(by: -1, signal: batch.signal)
      diagnostics.recordDrop(signal: batch.signal)
    }
  }

  func disableAndDiscardPending() -> RuntimeDiscardOutcome {
    if let discardOutcome {
      return discardOutcome
    }

    isShutdown = true
    worker?.cancel()
    worker = nil

    let pending = queue + [inFlight].compactMap { $0 }
    queue.removeAll()
    inFlight = nil
    var discardedBySignal: [TelemetryRuntimeSignal: Int] = [:]
    for batch in pending {
      diagnostics.adjustQueueDepth(by: -1, signal: batch.signal)
      diagnostics.recordDrop(signal: batch.signal)
      discardedBySignal[batch.signal, default: 0] += 1
    }

    let purge =
      persistence?.removeAll()
      ?? PersistencePurgeResult(
        discardedBySignal: [:],
        failedBySignal: [:],
        failedFiles: 0,
        remainingItems: 0,
        remainingBytes: 0
      )
    diagnostics.recordDiscard(completed: purge.failedFiles == 0 && purge.remainingItems == 0)
    let outcome = RuntimeDiscardOutcome(
      discardedBySignal: discardedBySignal,
      failedBySignal: purge.failedBySignal,
      failedPersistedFiles: purge.failedFiles,
      remainingPersistedItems: purge.remainingItems
    )
    if purge.failedFiles == 0 && purge.remainingItems == 0 {
      discardOutcome = outcome
    }
    return outcome
  }

  func pendingBySignal() -> [TelemetryRuntimeSignal: Int] {
    var result = Dictionary(
      uniqueKeysWithValues: TelemetryRuntimeSignal.allCases.map { ($0, 0) }
    )
    for batch in queue {
      result[batch.signal, default: 0] += 1
    }
    if let inFlight {
      result[inFlight.signal, default: 0] += 1
    }
    return result
  }

  private var pendingCount: Int {
    queue.count + (inFlight == nil ? 0 : 1)
  }

  private func startWorkerIfNeeded() {
    guard worker == nil, !isShutdown, condition != .unavailable, !queue.isEmpty else {
      return
    }
    worker = Task { [weak self] in
      await self?.runWorker()
    }
  }

  private func runWorker() async {
    while !Task.isCancelled, !isShutdown, condition != .unavailable, !queue.isEmpty {
      var batch = queue.removeFirst()
      inFlight = batch

      batch.attempt += 1
      inFlight = batch
      if let persistence, !persistence.save(batch).saved {
        finish(batch)
        diagnostics.recordDrop(signal: batch.signal)
        continue
      }

      diagnostics.recordAttempt(signal: batch.signal)
      let outcome = await attempt(batch)
      if Task.isCancelled || isShutdown {
        if !isShutdown {
          inFlight = batch
        }
        break
      }

      switch outcome {
      case .success:
        diagnostics.recordSuccess(signal: batch.signal, at: clock.now())
        finish(batch)
      case .nonRetryable:
        diagnostics.recordFailure(signal: batch.signal, retryable: false)
        diagnostics.recordDrop(signal: batch.signal)
        finish(batch)
      case .retryable(let retryAfter):
        diagnostics.recordFailure(signal: batch.signal, retryable: true)
        guard batch.attempt < configuration.retry.maximumAttempts else {
          diagnostics.recordDrop(signal: batch.signal)
          finish(batch)
          continue
        }
        do {
          try await clock.sleep(retryDelay(after: batch.attempt, retryAfter: retryAfter))
        } catch {
          if !isShutdown {
            inFlight = batch
          }
          break
        }
        inFlight = nil
        queue.insert(batch, at: 0)
      }
    }
    worker = nil
    if !isShutdown {
      startWorkerIfNeeded()
    }
  }

  private func finish(_ batch: PendingOTLPBatch) {
    persistence?.remove(batch.id)
    inFlight = nil
    diagnostics.adjustQueueDepth(by: -1, signal: batch.signal)
  }

  private func attempt(_ batch: PendingOTLPBatch) async -> AttemptOutcome {
    let race = RuntimeAttemptRace()
    let operation = Task { [authenticator, transport] in
      do {
        var request = try await authenticator.authorize(batch.request)
        request.timeoutInterval = configuration.requestTimeout.runtimeSeconds
        let response = try await transport.send(request)
        race.resolve(Self.classify(response: response))
      } catch {
        race.resolve(Self.classify(error: error))
      }
    }
    let timeout = Task { [clock, configuration] in
      do {
        try await clock.sleep(configuration.requestTimeout)
        race.resolve(.retryable(retryAfter: nil))
      } catch {
      }
    }
    race.install(operation: operation, timeout: timeout)
    return await withTaskCancellationHandler {
      await race.value()
    } onCancel: {
      race.resolve(.nonRetryable)
    }
  }

  private func backoff(after attempt: Int) -> Duration {
    let retry = configuration.retry
    let exponent = max(0, attempt - 1)
    let base = min(
      retry.maximumBackoff.runtimeSeconds,
      retry.initialBackoff.runtimeSeconds * pow(2, Double(exponent))
    )
    let random = min(1, max(0, clock.randomUnit()))
    let multiplier = 1 + retry.jitterRatio * ((2 * random) - 1)
    return .runtimeSeconds(max(0, base * multiplier))
  }

  private func retryDelay(after attempt: Int, retryAfter: Duration?) -> Duration {
    guard let retryAfter else {
      return backoff(after: attempt)
    }
    let seconds = retryAfter.runtimeSeconds
    guard seconds.isFinite, seconds >= 0 else {
      return backoff(after: attempt)
    }
    return .runtimeSeconds(min(seconds, configuration.retry.maximumBackoff.runtimeSeconds))
  }

  private static func classify(response: TelemetryHTTPResponse) -> AttemptOutcome {
    if (200..<300).contains(response.statusCode) {
      return .success
    }
    if response.statusCode == 408 || response.statusCode == 425 || response.statusCode == 429
      || response.statusCode == 502 || response.statusCode == 503 || response.statusCode == 504
    {
      return .retryable(retryAfter: response.retryAfter)
    }
    return .nonRetryable
  }

  private static func classify(error: any Error) -> AttemptOutcome {
    if let error = error as? any TelemetryRetryClassifyingError {
      return error.telemetryRetryable ? .retryable(retryAfter: nil) : .nonRetryable
    }
    guard let error = error as? URLError else {
      return .nonRetryable
    }
    switch error.code {
    case .timedOut,
      .cannotFindHost,
      .cannotConnectToHost,
      .networkConnectionLost,
      .dnsLookupFailed,
      .notConnectedToInternet,
      .internationalRoamingOff,
      .callIsActive,
      .dataNotAllowed:
      return .retryable(retryAfter: nil)
    default:
      return .nonRetryable
    }
  }

  private static func accepts(
    request: URLRequest,
    maximumEncodedRequestBytes: Int
  ) -> Bool {
    request.httpBodyStream == nil
      && (request.httpBody?.count ?? 0) <= maximumEncodedRequestBytes
  }
}

private enum AttemptOutcome: Sendable {
  case success
  case retryable(retryAfter: Duration?)
  case nonRetryable
}

private final class RuntimeAttemptRace: @unchecked Sendable {
  private let lock = NSLock()
  private let stream: AsyncStream<AttemptOutcome>
  private let continuation: AsyncStream<AttemptOutcome>.Continuation
  private var operation: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var resolved = false

  init() {
    let pair = Self.makeStream()
    stream = pair.stream
    continuation = pair.continuation
  }

  deinit {
    continuation.finish()
  }

  func install(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
    let shouldCancel = lock.withLock {
      self.operation = operation
      self.timeout = timeout
      return resolved
    }
    if shouldCancel {
      operation.cancel()
      timeout.cancel()
    }
  }

  func value() async -> AttemptOutcome {
    for await result in stream {
      return result
    }
    return .nonRetryable
  }

  func resolve(_ result: AttemptOutcome) {
    let accepted: (Task<Void, Never>?, Task<Void, Never>?)? = lock.withLock {
      guard !resolved else { return nil }
      resolved = true
      return (operation, timeout)
    }
    guard let accepted else { return }
    accepted.0?.cancel()
    accepted.1?.cancel()
    continuation.yield(result)
    continuation.finish()
  }

  private static func makeStream() -> (
    stream: AsyncStream<AttemptOutcome>,
    continuation: AsyncStream<AttemptOutcome>.Continuation
  ) {
    var continuation: AsyncStream<AttemptOutcome>.Continuation?
    let stream = AsyncStream(
      AttemptOutcome.self,
      bufferingPolicy: .bufferingNewest(1)
    ) {
      continuation = $0
    }
    return (stream, continuation!)
  }
}

final class RuntimeOTLPHTTPClient: HTTPClient, @unchecked Sendable {
  private let signal: TelemetryRuntimeSignal
  private let delivery: RuntimeDeliveryEngine

  init(signal: TelemetryRuntimeSignal, delivery: RuntimeDeliveryEngine) {
    self.signal = signal
    self.delivery = delivery
  }

  func send(
    request: URLRequest,
    completion: @escaping (Result<HTTPURLResponse, any Error>) -> Void
  ) {
    let completion = RuntimeHTTPCompletion(completion)
    let semaphore = DispatchSemaphore(value: 0)
    Task { [signal, delivery] in
      _ = await delivery.enqueue(request: request, signal: signal)
      guard let url = request.url,
        let response = HTTPURLResponse(
          url: url,
          statusCode: 202,
          httpVersion: "HTTP/1.1",
          headerFields: nil
        )
      else {
        completion.call(.failure(TelemetryRuntimeTransportError.invalidResponse))
        semaphore.signal()
        return
      }
      completion.call(.success(response))
      semaphore.signal()
    }
    semaphore.wait()
  }
}

private final class RuntimeHTTPCompletion: @unchecked Sendable {
  private let operation: (Result<HTTPURLResponse, any Error>) -> Void

  init(_ operation: @escaping (Result<HTTPURLResponse, any Error>) -> Void) {
    self.operation = operation
  }

  func call(_ result: Result<HTTPURLResponse, any Error>) {
    operation(result)
  }
}
