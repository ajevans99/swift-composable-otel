import Foundation
import OpenTelemetrySdk

/// Collects exported spans in memory for test assertions.
public final class InMemorySpanCollector: SpanExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var _spans: [SpanData] = []

  public init() {}

  /// All spans collected so far.
  public var spans: [SpanData] {
    lock.lock()
    defer { lock.unlock() }
    return _spans
  }

  // MARK: - SpanExporter

  @discardableResult
  public func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    lock.lock()
    defer { lock.unlock() }
    _spans.append(contentsOf: spans)
    return .success
  }

  public func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    .success
  }

  public func shutdown(explicitTimeout: TimeInterval?) {}

  // MARK: - Test helpers

  /// Remove all collected spans.
  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    _spans.removeAll()
  }
}
