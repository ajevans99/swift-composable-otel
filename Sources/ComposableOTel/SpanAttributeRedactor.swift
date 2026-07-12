import OpenTelemetryApi

/// Contract for redacting sensitive span attributes in a future bounded export pipeline.
///
/// The current exporters do not invoke this protocol.
public protocol SpanAttributeRedactor: Sendable {
  func redact(_ attributes: inout [String: AttributeValue])
}

/// No-op redactor that leaves attributes unchanged.
public struct NoOpRedactor: SpanAttributeRedactor {
  public init() {}
  public func redact(_ attributes: inout [String: AttributeValue]) {}
}
