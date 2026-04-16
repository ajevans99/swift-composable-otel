import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import StdoutExporter
import ComposableOTel

/// Configures OpenTelemetry providers for a TCA application.
public enum TelemetryBootstrap {
  /// The deployment environment for telemetry configuration.
  public enum Environment: Sendable {
    /// Console output for development. Uses StdoutExporter.
    case debug
    /// Production configuration with OTLP endpoint.
    case production(endpoint: String, headers: [String: String] = [:])
  }

  /// Configure telemetry with environment-appropriate defaults.
  ///
  /// - Parameters:
  ///   - serviceName: The service name resource attribute (e.g., "my-ios-app").
  ///   - serviceVersion: Optional service version. Auto-detected from Bundle if nil.
  ///   - environment: The deployment environment.
  ///   - samplingRatio: Trace sampling ratio (0.0 to 1.0). Default: 1.0 for debug, 0.1 for production.
  ///   - errorDetailPolicy: How error details are handled in telemetry.
  public static func configure(
    serviceName: String,
    serviceVersion: String? = nil,
    environment: Environment = .debug,
    samplingRatio: Double? = nil,
    errorDetailPolicy: ErrorDetailPolicy = .redacted
  ) {
    // --- Resource ---

    let version = serviceVersion
      ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
      ?? "unknown"

    let deploymentEnv: String
    switch environment {
    case .debug: deploymentEnv = "debug"
    case .production: deploymentEnv = "production"
    }

    let resource = Resource(attributes: [
      "service.name": .string(serviceName),
      "service.version": .string(version),
      "deployment.environment": .string(deploymentEnv),
      "telemetry.sdk.name": .string("swift-composable-otel"),
      "telemetry.sdk.version": .string("0.1.0"),
      "os.type": .string("darwin"),
      "os.version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
    ])

    // --- Sampler ---

    let ratio: Double
    switch environment {
    case .debug: ratio = samplingRatio ?? 1.0
    case .production: ratio = samplingRatio ?? 0.1
    }

    let sampler = Samplers.parentBased(root: Samplers.traceIdRatio(ratio: ratio))

    // --- Traces ---

    let spanExporter: SpanExporter
    switch environment {
    case .debug:
      spanExporter = StdoutSpanExporter(isDebug: true)
    case .production:
      // TODO: Replace with OtlpTraceExporter once OTLP support is added.
      // The production endpoint and headers from Environment.production are
      // reserved for that integration.
      spanExporter = StdoutSpanExporter(isDebug: false)
    }

    let spanProcessor = SimpleSpanProcessor(spanExporter: spanExporter)

    let tracerProvider = TracerProviderBuilder()
      .with(resource: resource)
      .with(sampler: sampler)
      .add(spanProcessor: spanProcessor)
      .build()

    OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

    // --- Metrics ---

    let metricExporter: StdoutMetricExporter
    switch environment {
    case .debug:
      metricExporter = StdoutMetricExporter(isDebug: true)
    case .production:
      // TODO: Replace with OtlpMetricExporter once OTLP support is added.
      metricExporter = StdoutMetricExporter(isDebug: false)
    }

    let metricInterval: TimeInterval
    switch environment {
    case .debug: metricInterval = 5.0
    case .production: metricInterval = 60.0
    }

    let metricReader = PeriodicMetricReaderBuilder(exporter: metricExporter)
      .setInterval(timeInterval: metricInterval)
      .build()

    let meterProvider = MeterProviderSdk.builder()
      .setResource(resource: resource)
      .registerMetricReader(reader: metricReader)
      .build()

    OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)

    // --- Shared configuration ---

    TelemetryConfiguration.shared.errorDetailPolicy = errorDetailPolicy
  }
}
