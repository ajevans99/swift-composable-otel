import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// A thread-safe, in-memory log record exporter for tests.
///
/// Collects all emitted log records so tests can assert on log output
/// from `telemetry.info()`, `telemetry.error()`, etc.
///
/// ```swift
/// let (client, collectors) = TelemetryClient.test()
/// // ... exercise actions ...
/// let errorLogs = collectors.logs.records(withSeverity: .error)
/// #expect(!errorLogs.isEmpty)
/// ```
public final class InMemoryLogCollector: LogRecordExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [ReadableLogRecord] = []

  public init() {}

  // MARK: - LogRecordExporter

  public func export(
    logRecords: [ReadableLogRecord],
    explicitTimeout: TimeInterval? = nil
  ) -> ExportResult {
    lock.lock()
    defer { lock.unlock() }
    records.append(contentsOf: logRecords)
    return .success
  }

  public func shutdown(explicitTimeout: TimeInterval? = nil) {
    lock.lock()
    defer { lock.unlock() }
    records.removeAll()
  }

  public func forceFlush(explicitTimeout: TimeInterval? = nil) -> ExportResult {
    .success
  }

  // MARK: - Query API

  /// All collected log records.
  public var allRecords: [ReadableLogRecord] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }

  /// Log records matching the given severity.
  public func records(withSeverity severity: Severity) -> [ReadableLogRecord] {
    allRecords.filter { $0.severity == severity }
  }

  /// Log records whose body contains the given substring.
  public func records(containing substring: String) -> [ReadableLogRecord] {
    allRecords.filter { record in
      if case .string(let body) = record.body {
        return body.contains(substring)
      }
      return false
    }
  }

  /// Resets all collected records.
  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    records.removeAll()
  }
}
