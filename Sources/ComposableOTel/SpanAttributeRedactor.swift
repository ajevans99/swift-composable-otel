import OpenTelemetryApi

/// Protocol for redacting sensitive span attributes before export.
public protocol SpanAttributeRedactor: Sendable {
  func redact(_ attributes: inout [String: AttributeValue])
}

/// Default no-op redactor that passes attributes through unchanged.
public struct NoOpRedactor: SpanAttributeRedactor {
  public init() {}
  public func redact(_ attributes: inout [String: AttributeValue]) {}
}
