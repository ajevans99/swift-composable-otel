import OpenTelemetryApi

/// Provides structured logging for TCA events via OpenTelemetry's ``LoggerProvider``.
///
/// Log records are emitted through the globally-registered ``LoggerProvider``.
/// When no SDK is configured the default no-op provider silently discards records.
public struct TCALogger: Sendable {
  public static let shared = TCALogger()

  private init() {}

  private var logger: any OpenTelemetryApi.Logger {
    OpenTelemetry.instance.loggerProvider
      .loggerBuilder(instrumentationScopeName: "ComposableOTel")
      .setInstrumentationVersion("0.1.0")
      .build()
  }

  /// Emit a log record with the given severity, body, and optional attributes.
  public func log(
    severity: Severity,
    body: String,
    attributes: [String: AttributeValue] = [:]
  ) {
    logger.logRecordBuilder()
      .setSeverity(severity)
      .setBody(.string(body))
      .setAttributes(attributes)
      .emit()
  }

  public func error(_ body: String, attributes: [String: AttributeValue] = [:]) {
    log(severity: .error, body: body, attributes: attributes)
  }

  public func warn(_ body: String, attributes: [String: AttributeValue] = [:]) {
    log(severity: .warn, body: body, attributes: attributes)
  }

  public func info(_ body: String, attributes: [String: AttributeValue] = [:]) {
    log(severity: .info, body: body, attributes: attributes)
  }

  public func debug(_ body: String, attributes: [String: AttributeValue] = [:]) {
    log(severity: .debug, body: body, attributes: attributes)
  }
}
