import Foundation
import OpenTelemetrySdk

/// A span exporter that formats TCA telemetry for readable console output.
///
/// Output format:
/// ```
/// [SPAN] reducer/GoalList • goalRowTapped • 2.3ms • state_changed=true
/// ```
public final class ConsoleSpanExporter: SpanExporter {
  public init() {}

  @discardableResult
  public func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    for span in spans {
      let durationMs = span.endTime.timeIntervalSince(span.startTime) * 1000
      let name = span.name
      let action = span.attributes["tca.action.type"]?.description ?? ""
      let indent = String(repeating: "  ", count: depthFromParent(span))

      var parts = ["\(indent)[SPAN] \(name)"]
      if !action.isEmpty { parts.append(action) }
      parts.append(String(format: "%.1fms", durationMs))

      if let changed = span.attributes["tca.state.changed"] {
        parts.append("state_changed=\(changed)")
      }

      print(parts.joined(separator: " • "))
    }
    return .success
  }

  public func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }

  public func shutdown(explicitTimeout: TimeInterval?) {}

  private func depthFromParent(_ span: SpanData) -> Int {
    span.parentSpanId != nil ? 1 : 0
  }
}
