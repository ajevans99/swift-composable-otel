import Foundation
import OpenTelemetrySdk

final class ObserverSpanExporter: SpanExporter, @unchecked Sendable {
  private let lock = NSLock()
  private let result: SpanExporterResultCode
  private var storage: [SpanData] = []
  private var _flushCount = 0
  private var _shutdownCount = 0

  init(result: SpanExporterResultCode = .success) {
    self.result = result
  }

  var spans: [SpanData] {
    lock.withLock { storage }
  }

  var flushCount: Int {
    lock.withLock { _flushCount }
  }

  var shutdownCount: Int {
    lock.withLock { _shutdownCount }
  }

  func export(
    spans: [SpanData],
    explicitTimeout: TimeInterval?
  ) -> SpanExporterResultCode {
    lock.withLock {
      storage.append(contentsOf: spans)
    }
    return result
  }

  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    lock.withLock {
      _flushCount += 1
    }
    return result
  }

  func shutdown(explicitTimeout: TimeInterval?) {
    lock.withLock {
      _shutdownCount += 1
    }
  }
}

final class ObserverLogRecordExporter: LogRecordExporter, @unchecked Sendable {
  private let lock = NSLock()
  private let result: ExportResult
  private var storage: [ReadableLogRecord] = []
  private var _flushCount = 0
  private var _shutdownCount = 0

  init(result: ExportResult = .success) {
    self.result = result
  }

  var records: [ReadableLogRecord] {
    lock.withLock { storage }
  }

  var flushCount: Int {
    lock.withLock { _flushCount }
  }

  var shutdownCount: Int {
    lock.withLock { _shutdownCount }
  }

  func export(
    logRecords: [ReadableLogRecord],
    explicitTimeout: TimeInterval?
  ) -> ExportResult {
    lock.withLock {
      storage.append(contentsOf: logRecords)
    }
    return result
  }

  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    lock.withLock {
      _flushCount += 1
    }
    return result
  }

  func shutdown(explicitTimeout: TimeInterval?) {
    lock.withLock {
      _shutdownCount += 1
    }
  }
}

final class ObserverMetricExporter: MetricExporter, @unchecked Sendable {
  private let lock = NSLock()
  private let result: ExportResult
  private var storage: [MetricData] = []
  private var _flushCount = 0
  private var _shutdownCount = 0

  init(result: ExportResult = .success) {
    self.result = result
  }

  var metrics: [MetricData] {
    lock.withLock { storage }
  }

  var flushCount: Int {
    lock.withLock { _flushCount }
  }

  var shutdownCount: Int {
    lock.withLock { _shutdownCount }
  }

  func export(metrics: [MetricData]) -> ExportResult {
    lock.withLock {
      storage.append(contentsOf: metrics)
    }
    return result
  }

  func flush() -> ExportResult {
    lock.withLock {
      _flushCount += 1
    }
    return result
  }

  func shutdown() -> ExportResult {
    lock.withLock {
      _shutdownCount += 1
    }
    return result
  }

  func getAggregationTemporality(
    for instrument: InstrumentType
  ) -> AggregationTemporality {
    .cumulative
  }
}
