import Foundation

/// A bounded diagnostic emitted outside the telemetry pipeline.
public struct TelemetryRuntimeDiagnosticEvent: Sendable {
  public enum Kind: Sendable {
    case queueDepth
    case dropped
    case persisted
    case attempt
    case success
    case retryableFailure
    case nonRetryableFailure
    case corruptionRecovered
    case flushCompleted
    case flushTimedOut
    case discardCompleted
    case discardFailed
    case encodedRequestTooLarge
  }

  public let kind: Kind
  public let signal: TelemetryRuntimeSignal?
  public let value: Int

  public init(kind: Kind, signal: TelemetryRuntimeSignal? = nil, value: Int = 1) {
    self.kind = kind
    self.signal = signal
    self.value = value
  }
}

/// Per-signal delivery state captured without exporting another telemetry signal.
public struct TelemetrySignalDiagnostics: Equatable, Sendable {
  public let queueDepth: Int
  public let droppedItems: Int
  public let attempts: Int
  public let successes: Int
  public let retryableFailures: Int
  public let nonRetryableFailures: Int
  public let oversizedRequests: Int
  public let lastSuccess: Date?
}

/// A point-in-time snapshot of bounded runtime diagnostics.
public struct TelemetryRuntimeDiagnostics: Equatable, Sendable {
  public let traces: TelemetrySignalDiagnostics
  public let metrics: TelemetrySignalDiagnostics
  public let logs: TelemetrySignalDiagnostics
  public let persistedItems: Int
  public let persistedBytes: Int
  public let recoveredCorruptFiles: Int
  public let completedFlushes: Int
  public let timedOutFlushes: Int
  public let completedDiscards: Int
  public let failedDiscards: Int

  public func signal(_ signal: TelemetryRuntimeSignal) -> TelemetrySignalDiagnostics {
    switch signal {
    case .traces:
      traces
    case .metrics:
      metrics
    case .logs:
      logs
    }
  }
}

/// The bounded result for one signal during a flush or shutdown operation.
public struct TelemetrySignalOperationResult: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case success
    case timedOut
    case failed
    case disabled
  }

  public let status: Status
  public let pendingItems: Int
  public let droppedItems: Int
}

/// Structured aggregate result for runtime lifecycle operations.
public struct TelemetryRuntimeOperationResult: Equatable, Sendable {
  public enum Operation: Equatable, Sendable {
    case forceFlush
    case background
    case shutdown
    case disableAndDiscardPending
  }

  public let operation: Operation
  public let traces: TelemetrySignalOperationResult
  public let metrics: TelemetrySignalOperationResult
  public let logs: TelemetrySignalOperationResult
  public let persistedItems: Int

  public var succeeded: Bool {
    let signalsSucceeded = [traces, metrics, logs].allSatisfy {
      $0.status == .success || $0.status == .disabled
    }
    return signalsSucceeded
      && (operation != .disableAndDiscardPending || persistedItems == 0)
  }
}

final class RuntimeDiagnosticsState: @unchecked Sendable {
  private struct MutableSignal {
    var queueDepth = 0
    var droppedItems = 0
    var attempts = 0
    var successes = 0
    var retryableFailures = 0
    var nonRetryableFailures = 0
    var oversizedRequests = 0
    var lastSuccess: Date?
  }

  private let lock = NSLock()
  private var signals = Dictionary(
    uniqueKeysWithValues: TelemetryRuntimeSignal.allCases.map { ($0, MutableSignal()) }
  )
  private var persistedItems = 0
  private var persistedBytes = 0
  private var recoveredCorruptFiles = 0
  private var completedFlushes = 0
  private var timedOutFlushes = 0
  private var completedDiscards = 0
  private var failedDiscards = 0
  private let emitter: RuntimeDiagnosticEmitter

  init(handler: (@Sendable (TelemetryRuntimeDiagnosticEvent) -> Void)?) {
    emitter = RuntimeDiagnosticEmitter(handler: handler)
  }

  func adjustQueueDepth(by delta: Int, signal: TelemetryRuntimeSignal) {
    let depth = lock.withLock {
      var value = signals[signal] ?? MutableSignal()
      value.queueDepth = max(0, value.queueDepth + delta)
      signals[signal] = value
      return value.queueDepth
    }
    emitter.emit(.init(kind: .queueDepth, signal: signal, value: depth))
  }

  func recordDrop(signal: TelemetryRuntimeSignal, count: Int = 1) {
    lock.withLock {
      signals[signal]?.droppedItems += count
    }
    emitter.emit(.init(kind: .dropped, signal: signal, value: count))
  }

  func recordAttempt(signal: TelemetryRuntimeSignal) {
    lock.withLock {
      signals[signal]?.attempts += 1
    }
    emitter.emit(.init(kind: .attempt, signal: signal))
  }

  func recordSuccess(signal: TelemetryRuntimeSignal, at date: Date) {
    lock.withLock {
      signals[signal]?.successes += 1
      signals[signal]?.lastSuccess = date
    }
    emitter.emit(.init(kind: .success, signal: signal))
  }

  func recordFailure(signal: TelemetryRuntimeSignal, retryable: Bool) {
    lock.withLock {
      if retryable {
        signals[signal]?.retryableFailures += 1
      } else {
        signals[signal]?.nonRetryableFailures += 1
      }
    }
    emitter.emit(
      .init(
        kind: retryable ? .retryableFailure : .nonRetryableFailure,
        signal: signal
      )
    )
  }

  func recordEncodedRequestTooLarge(signal: TelemetryRuntimeSignal) {
    lock.withLock {
      signals[signal]?.oversizedRequests += 1
    }
    emitter.emit(.init(kind: .encodedRequestTooLarge, signal: signal))
  }

  func setPersistence(items: Int, bytes: Int) {
    lock.withLock {
      persistedItems = max(0, items)
      persistedBytes = max(0, bytes)
    }
    emitter.emit(.init(kind: .persisted, value: max(0, items)))
  }

  func recordCorruptionRecovery(count: Int = 1) {
    lock.withLock {
      recoveredCorruptFiles += count
    }
    emitter.emit(.init(kind: .corruptionRecovered, value: count))
  }

  func recordFlush(completed: Bool) {
    lock.withLock {
      if completed {
        completedFlushes += 1
      } else {
        timedOutFlushes += 1
      }
    }
    emitter.emit(.init(kind: completed ? .flushCompleted : .flushTimedOut))
  }

  func recordDiscard(completed: Bool) {
    lock.withLock {
      if completed {
        completedDiscards += 1
      } else {
        failedDiscards += 1
      }
    }
    emitter.emit(.init(kind: completed ? .discardCompleted : .discardFailed))
  }

  func snapshot() -> TelemetryRuntimeDiagnostics {
    lock.withLock {
      TelemetryRuntimeDiagnostics(
        traces: snapshot(.traces),
        metrics: snapshot(.metrics),
        logs: snapshot(.logs),
        persistedItems: persistedItems,
        persistedBytes: persistedBytes,
        recoveredCorruptFiles: recoveredCorruptFiles,
        completedFlushes: completedFlushes,
        timedOutFlushes: timedOutFlushes,
        completedDiscards: completedDiscards,
        failedDiscards: failedDiscards
      )
    }
  }

  private func snapshot(_ signal: TelemetryRuntimeSignal) -> TelemetrySignalDiagnostics {
    let value = signals[signal] ?? MutableSignal()
    return TelemetrySignalDiagnostics(
      queueDepth: value.queueDepth,
      droppedItems: value.droppedItems,
      attempts: value.attempts,
      successes: value.successes,
      retryableFailures: value.retryableFailures,
      nonRetryableFailures: value.nonRetryableFailures,
      oversizedRequests: value.oversizedRequests,
      lastSuccess: value.lastSuccess
    )
  }
}

private final class RuntimeDiagnosticEmitter: @unchecked Sendable {
  private let handler: (@Sendable (TelemetryRuntimeDiagnosticEvent) -> Void)?
  private let recursionKey = "com.swift-composable-otel.runtime-diagnostic"

  init(handler: (@Sendable (TelemetryRuntimeDiagnosticEvent) -> Void)?) {
    self.handler = handler
  }

  func emit(_ event: TelemetryRuntimeDiagnosticEvent) {
    guard let handler else { return }
    let dictionary = Thread.current.threadDictionary
    guard dictionary[recursionKey] == nil else { return }
    dictionary[recursionKey] = true
    defer {
      dictionary.removeObject(forKey: recursionKey)
    }
    handler(event)
  }
}
