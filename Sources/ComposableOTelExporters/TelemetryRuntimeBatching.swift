import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

enum RuntimeBatchQueueOfferResult {
  case accepted
  case dropped
  case stopped
}

final class RuntimeBatchQueue<Item: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private let configuration: TelemetryBatchConfiguration
  private let signal: TelemetryRuntimeSignal
  private let diagnostics: RuntimeDiagnosticsState
  private let clock: TelemetryRuntimeClock
  private let export: @Sendable ([Item], TimeInterval) -> Bool
  private let shutdownExporter: @Sendable (TimeInterval) -> Void
  private let workerQueue: DispatchQueue

  private var items: [Item] = []
  private var accepting = true
  private var exporting = false
  private var flushRequested = false
  private var scheduledTask: Task<Void, Never>?
  private var scheduleGeneration = 0
  private var flushWaiters: [CheckedContinuation<Void, Never>] = []
  private var exporterWasShutdown = false

  init(
    configuration: TelemetryBatchConfiguration,
    signal: TelemetryRuntimeSignal,
    diagnostics: RuntimeDiagnosticsState,
    clock: TelemetryRuntimeClock,
    export: @escaping @Sendable ([Item], TimeInterval) -> Bool,
    shutdownExporter: @escaping @Sendable (TimeInterval) -> Void
  ) {
    self.configuration = configuration
    self.signal = signal
    self.diagnostics = diagnostics
    self.clock = clock
    self.export = export
    self.shutdownExporter = shutdownExporter
    workerQueue = DispatchQueue(
      label: "com.swift-composable-otel.batch.\(signal.rawValue)",
      qos: .utility
    )
  }

  @discardableResult
  func offer(_ item: Item) -> RuntimeBatchQueueOfferResult {
    var batch: [Item]?
    var queueDelta = 0
    var dropped = 0
    var result = RuntimeBatchQueueOfferResult.accepted
    lock.lock()
    if !accepting {
      dropped = 1
      result = .stopped
    } else if items.count >= configuration.maximumQueueSize {
      dropped = 1
      switch configuration.overflowPolicy {
      case .dropNewest:
        result = .dropped
        break
      case .dropOldest:
        items.removeFirst()
        items.append(item)
      }
    } else {
      items.append(item)
      queueDelta = 1
    }

    if accepting, items.count >= configuration.maximumBatchSize, !exporting {
      batch = takeBatchLocked()
      queueDelta -= batch?.count ?? 0
    } else if accepting, !items.isEmpty, !exporting {
      scheduleLocked()
    }
    lock.unlock()

    if queueDelta != 0 {
      diagnostics.adjustQueueDepth(by: queueDelta, signal: signal)
    }
    if dropped > 0 {
      diagnostics.recordDrop(signal: signal, count: dropped)
    }
    if let batch {
      startExport(batch)
    }
    return result
  }

  func forceFlush() async {
    await withCheckedContinuation { continuation in
      var batch: [Item]?
      var queueDelta = 0
      var resumeImmediately = false
      lock.lock()
      flushRequested = true
      cancelScheduleLocked()
      if exporting {
        flushWaiters.append(continuation)
      } else if items.isEmpty {
        flushRequested = false
        resumeImmediately = true
      } else {
        flushWaiters.append(continuation)
        batch = takeBatchLocked()
        queueDelta = -(batch?.count ?? 0)
      }
      lock.unlock()

      if queueDelta != 0 {
        diagnostics.adjustQueueDepth(by: queueDelta, signal: signal)
      }
      if resumeImmediately {
        continuation.resume()
      } else if let batch {
        startExport(batch)
      }
    }
  }

  func shutdown() async {
    let shouldShutdown = lock.withLock {
      accepting = false
      cancelScheduleLocked()
      guard !exporterWasShutdown else { return false }
      exporterWasShutdown = true
      return true
    }
    guard shouldShutdown else { return }
    await forceFlush()
    let timeout = configuration.exportTimeout.runtimeSeconds
    await withCheckedContinuation { continuation in
      workerQueue.async { [shutdownExporter] in
        shutdownExporter(timeout)
        continuation.resume()
      }
    }
  }

  func disableAndDiscardPending() async -> Int {
    var waiters: [CheckedContinuation<Void, Never>] = []
    let state = lock.withLock {
      accepting = false
      cancelScheduleLocked()
      let discarded = items.count
      items.removeAll()
      flushRequested = false
      waiters = flushWaiters
      flushWaiters.removeAll()
      let shouldShutdown = !exporterWasShutdown
      exporterWasShutdown = true
      return (discarded, shouldShutdown)
    }

    if state.0 > 0 {
      diagnostics.adjustQueueDepth(by: -state.0, signal: signal)
      diagnostics.recordDrop(signal: signal, count: state.0)
    }
    for waiter in waiters {
      waiter.resume()
    }
    guard state.1 else { return state.0 }

    let timeout = configuration.exportTimeout.runtimeSeconds
    await withCheckedContinuation { continuation in
      workerQueue.async { [shutdownExporter] in
        shutdownExporter(timeout)
        continuation.resume()
      }
    }
    return state.0
  }

  func stopAccepting() {
    lock.withLock {
      accepting = false
      cancelScheduleLocked()
    }
  }

  func requestFlush() {
    Task { [weak self] in
      await self?.forceFlush()
    }
  }

  var pendingCount: Int {
    lock.withLock {
      items.count + (exporting ? 1 : 0)
    }
  }

  private func scheduleLocked() {
    guard scheduledTask == nil else { return }
    scheduleGeneration += 1
    let generation = scheduleGeneration
    scheduledTask = Task { [weak self, clock, configuration] in
      do {
        try await clock.sleep(configuration.scheduledDelay)
      } catch {
        return
      }
      self?.scheduledDelayElapsed(generation: generation)
    }
  }

  private func scheduledDelayElapsed(generation: Int) {
    var batch: [Item]?
    lock.lock()
    guard generation == scheduleGeneration, !exporting, !items.isEmpty else {
      lock.unlock()
      return
    }
    scheduledTask = nil
    batch = takeBatchLocked()
    lock.unlock()

    if let batch {
      diagnostics.adjustQueueDepth(by: -batch.count, signal: signal)
      startExport(batch)
    }
  }

  private func takeBatchLocked() -> [Item] {
    cancelScheduleLocked()
    let count = min(configuration.maximumBatchSize, items.count)
    let batch = Array(items.prefix(count))
    items.removeFirst(count)
    exporting = true
    return batch
  }

  private func cancelScheduleLocked() {
    scheduledTask?.cancel()
    scheduledTask = nil
    scheduleGeneration += 1
  }

  private func startExport(_ batch: [Item]) {
    let timeout = configuration.exportTimeout.runtimeSeconds
    workerQueue.async { [weak self, export] in
      let succeeded = export(batch, timeout)
      self?.exportFinished(succeeded: succeeded, itemCount: batch.count)
    }
  }

  private func exportFinished(succeeded: Bool, itemCount: Int) {
    var nextBatch: [Item]?
    var queueDelta = 0
    let dropped = succeeded ? 0 : itemCount
    var waiters: [CheckedContinuation<Void, Never>] = []
    lock.lock()
    exporting = false
    if !items.isEmpty, flushRequested || items.count >= configuration.maximumBatchSize {
      nextBatch = takeBatchLocked()
      queueDelta = -(nextBatch?.count ?? 0)
    } else if !items.isEmpty, accepting {
      scheduleLocked()
    } else if items.isEmpty {
      flushRequested = false
      waiters = flushWaiters
      flushWaiters.removeAll()
    }
    lock.unlock()

    if queueDelta != 0 {
      diagnostics.adjustQueueDepth(by: queueDelta, signal: signal)
    }
    if dropped > 0 {
      diagnostics.recordDrop(signal: signal, count: dropped)
    }
    for waiter in waiters {
      waiter.resume()
    }
    if let nextBatch {
      startExport(nextBatch)
    }
  }
}

struct RuntimeSpanProcessor: SpanProcessor {
  let isStartRequired = false
  let isEndRequired = true
  let queue: RuntimeBatchQueue<SpanData>
  let boundary: TelemetryPrivacyBoundary

  func onStart(parentContext: SpanContext?, span: any ReadableSpan) {}

  mutating func onEnd(span: any ReadableSpan) {
    guard span.context.traceFlags.sampled,
      let sanitized = boundary.sanitizedSpans([span.toSpanData()]).first
    else { return }
    queue.offer(sanitized)
  }

  mutating func shutdown(explicitTimeout: TimeInterval?) {
    queue.stopAccepting()
  }

  func forceFlush(timeout: TimeInterval?) {
    queue.requestFlush()
  }
}

final class RuntimeLogRecordProcessor: LogRecordProcessor, @unchecked Sendable {
  let queue: RuntimeBatchQueue<ReadableLogRecord>
  let boundary: TelemetryPrivacyBoundary

  init(queue: RuntimeBatchQueue<ReadableLogRecord>, boundary: TelemetryPrivacyBoundary) {
    self.queue = queue
    self.boundary = boundary
  }

  func onEmit(logRecord: ReadableLogRecord) {
    guard let sanitized = boundary.sanitizedLogs([logRecord]).first else { return }
    queue.offer(sanitized)
  }

  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    queue.requestFlush()
    return .success
  }

  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    queue.stopAccepting()
    return .success
  }
}

func makeRuntimeOperationalEventRecorder(
  queue: RuntimeBatchQueue<ReadableLogRecord>,
  boundary: TelemetryPrivacyBoundary,
  resource: Resource,
  now: @escaping @Sendable () -> Date
) -> TelemetryOperationalEventRecorder {
  TelemetryOperationalEventRecorder { event in
    let record = ReadableLogRecord(
      resource: resource,
      instrumentationScopeInfo: InstrumentationScopeInfo(
        name: ComposableOTelMetadata.instrumentationName,
        version: ComposableOTelMetadata.version
      ),
      timestamp: now(),
      spanContext: OpenTelemetry.instance.contextProvider.activeSpan?.context,
      severity: .info,
      body: nil,
      attributes: event.attributes,
      eventName: event.eventName
    )
    guard let sanitized = boundary.sanitizedLogs([record]).first else {
      return .dropped
    }
    switch queue.offer(sanitized) {
    case .accepted:
      return .recorded
    case .dropped:
      return .dropped
    case .stopped:
      return .disabled
    }
  }
}
