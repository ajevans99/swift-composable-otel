import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import StdoutExporter

/// Configures OpenTelemetry providers for a TCA application.
public enum TelemetryBootstrap {
  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var client: TelemetryClient?

    func configure(_ makeClient: () -> TelemetryClient) -> TelemetryClient {
      lock.lock()
      defer { lock.unlock() }
      if let client {
        return client
      }
      let client = makeClient()
      self.client = client
      return client
    }
  }

  private static let state = State()

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
  /// The first call serializes global OTel provider registration and returns a cached
  /// `TelemetryClient` suitable for injecting into `DependencyValues.composableOTel`.
  /// All later calls return that same client without rebuilding or re-registering providers;
  /// therefore, the first configuration owns process-wide bootstrap settings.
  ///
  /// OpenTelemetry exposes its tracer, meter, and logger globals as separate writes. Call this
  /// method before starting compatibility code that reads those globals; normal ComposableOTel
  /// instrumentation uses only the returned client.
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
    state.configure {
      makeClient(
        serviceName: serviceName,
        serviceVersion: serviceVersion,
        environment: environment,
        samplingRatio: samplingRatio,
        errorDetailPolicy: errorDetailPolicy
      )
    }
  }

  private static func makeClient(
    serviceName: String,
    serviceVersion: String?,
    environment: Environment,
    samplingRatio: Double?,
    errorDetailPolicy: ErrorDetailPolicy
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
      .registerView(
        selector: InstrumentSelectorBuilder().build(),
        view: View.builder().build()
      )
      .build()

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
    let logger =
      loggerProvider
      .loggerBuilder(instrumentationScopeName: ComposableOTelMetadata.instrumentationName)
      .setInstrumentationVersion(ComposableOTelMetadata.version)
      .build()

    // OpenTelemetry exposes separate global setters, so publish them together only after every
    // provider and the injected client components are ready.
    OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)
    OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)
    OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

    return TelemetryClient(
      tracer: tracer,
      metrics: MetricInstruments(meter: meter),
      logger: logger,
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
