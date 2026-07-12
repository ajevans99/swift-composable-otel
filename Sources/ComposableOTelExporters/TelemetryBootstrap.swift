import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import StdoutExporter

/// Configures OpenTelemetry providers for a TCA application.
public enum TelemetryBootstrap {
  /// The deployment environment for telemetry configuration.
  public enum Environment: Sendable {
    /// Console output for development. Uses StdoutExporter.
    case debug
    /// Production-tuned sampling and intervals, still using StdoutExporter in this release.
    ///
    /// The endpoint and headers are reserved for the later OTLP runtime. They are not read and
    /// no telemetry is sent remotely by the current implementation.
    case production(endpoint: String, headers: [String: String] = [:])
  }

  /// Configure telemetry with environment-appropriate defaults.
  ///
  /// Registers global OTel providers and returns a `TelemetryClient` suitable for
  /// injecting into `DependencyValues.composableOTel`.
  ///
  /// Both environments export traces, metrics, and logs to standard output. Production OTLP
  /// transport and lifecycle management are not implemented in this release.
  ///
  /// ```swift
  /// // In App init:
  /// let client = TelemetryBootstrap.configure(serviceName: "my-app")
  /// // Then inject into store dependencies
  /// ```
  @discardableResult
  public static func configure(
    serviceName: String,
    serviceVersion: String? = nil,
    environment: Environment = .debug,
    samplingRatio: Double? = nil,
    errorDetailPolicy: ErrorDetailPolicy = .redacted
  ) -> TelemetryClient {
    // --- Resource ---

    let resource = makeResource(
      serviceName: serviceName,
      serviceVersion: serviceVersion,
      environment: environment
    )

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

    // --- Logs ---

    let logExporter: any LogRecordExporter
    switch environment {
    case .debug:
      logExporter = StdoutLogExporter(isDebug: true)
    case .production:
      logExporter = StdoutLogExporter(isDebug: false)
    }

    let logProcessor = SimpleLogRecordProcessor(logRecordExporter: logExporter)
    let loggerProvider = LoggerProviderSdk(
      resource: resource,
      logRecordProcessors: [logProcessor]
    )

    OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

    // --- Return a TelemetryClient for dependency injection ---

    let tracer = tracerProvider.get(
      instrumentationName: ComposableOTelMetadata.instrumentationName,
      instrumentationVersion: ComposableOTelMetadata.version
    )
    let meter =
      meterProvider
      .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
      .setInstrumentationVersion(instrumentationVersion: ComposableOTelMetadata.version)
      .build()

    return TelemetryClient(
      tracer: tracer,
      metrics: MetricInstruments(meter: meter),
      errorDetailPolicy: errorDetailPolicy
    )
  }

  static func makeResource(
    serviceName: String,
    serviceVersion: String?,
    environment: Environment
  ) -> Resource {
    let version =
      serviceVersion
      ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
      ?? "unknown"

    let deploymentEnvironment: String
    switch environment {
    case .debug: deploymentEnvironment = "debug"
    case .production: deploymentEnvironment = "production"
    }

    let packageResource = Resource(attributes: [
      "service.name": .string(serviceName),
      "service.version": .string(version),
      "deployment.environment": .string(deploymentEnvironment),
      "telemetry.distro.name": .string(ComposableOTelMetadata.packageName),
      "telemetry.distro.version": .string(ComposableOTelMetadata.version),
      "os.type": .string("darwin"),
      "os.version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
    ])
    return Resource().merging(other: packageResource)
  }
}
