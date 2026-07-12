import ComposableOTel
import Foundation
import OpenTelemetrySdk

/// A development-only privacy-preserving span exporter with compact console formatting.
///
/// Output format:
/// ```
/// [SPAN] tca.reducer • goal-row-tapped • 2.3ms • state_changed=true
/// ```
public final class ConsoleSpanExporter: SpanExporter, @unchecked Sendable {
  private let exporter: PrivacyPreservingSpanExporter

  public init(policy: TelemetryPolicy = .init()) {
    exporter = PrivacyPreservingSpanExporter(
      exporter: ConsoleSpanSink(),
      policy: policy
    )
  }

  @discardableResult
  public func export(
    spans: [SpanData],
    explicitTimeout: TimeInterval?
  ) -> SpanExporterResultCode {
    exporter.export(spans: spans, explicitTimeout: explicitTimeout)
  }

  public func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    exporter.flush(explicitTimeout: explicitTimeout)
  }

  public func shutdown(explicitTimeout: TimeInterval?) {
    exporter.shutdown(explicitTimeout: explicitTimeout)
  }

  @discardableResult
  public func export(
    spans: [SpanData],
    explicitTimeout: TimeInterval?
  ) async -> SpanExporterResultCode {
    await exporter.export(spans: spans, explicitTimeout: explicitTimeout)
  }

  public func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
    await exporter.flush(explicitTimeout: explicitTimeout)
  }

  public func shutdown(explicitTimeout: TimeInterval?) async {
    await exporter.shutdown(explicitTimeout: explicitTimeout)
  }
}

private final class ConsoleSpanSink: SpanExporter, @unchecked Sendable {
  @discardableResult
  func export(
    spans: [SpanData],
    explicitTimeout: TimeInterval?
  ) -> SpanExporterResultCode {
    for span in spans {
      let durationMs = span.endTime.timeIntervalSince(span.startTime) * 1_000
      let action = span.attributes[TCAAttributes.actionName]?.description ?? ""
      let indent = String(repeating: "  ", count: span.parentSpanId == nil ? 0 : 1)

      var parts = ["\(indent)[SPAN] \(span.name)"]
      if !action.isEmpty { parts.append(action) }
      parts.append(String(format: "%.1fms", durationMs))
      if let changed = span.attributes[TCAAttributes.stateChanged] {
        parts.append("state_changed=\(changed)")
      }
      print(parts.joined(separator: " • "))
    }
    return .success
  }

  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
  func shutdown(explicitTimeout: TimeInterval?) {}
}
