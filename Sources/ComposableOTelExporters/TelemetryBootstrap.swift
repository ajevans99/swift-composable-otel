import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import StdoutExporter

/// Configures the package-owned, privacy-preserving OpenTelemetry SDK pipeline.
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

  public enum Environment: Sendable {
    /// Privacy-preserving stdout export with full trace sampling.
    case debug
    /// Privacy-preserving stdout export with reduced trace sampling.
    ///
    /// Endpoint and headers remain reserved for issue #5 and are not read or contacted.
    case production(endpoint: String, headers: [String: String] = [:])
  }

  /// Configures bounded stdout telemetry once for the process.
  ///
  /// The first call owns the cached package client; OpenTelemetry process globals remain untouched.
  /// The policy controls each signal independently, and logs are disabled by default. Values
  /// outside the policy schema aggregate to `other`.
  @discardableResult
  public static func configure(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID? = nil,
    environment: Environment = .debug,
    samplingRatio: Double? = nil,
    policy: TelemetryPolicy = .init()
  ) -> TelemetryClient {
    state.configure {
      makeClient(
        serviceName: serviceName,
        serviceVersion: serviceVersion,
        environment: environment,
        samplingRatio: samplingRatio,
        policy: policy
      )
    }
  }

  private static func makeClient(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID?,
    environment: Environment,
    samplingRatio: Double?,
    policy: TelemetryPolicy
  ) -> TelemetryClient {
    let resource = makeResource(
      serviceName: serviceName,
      serviceVersion: serviceVersion,
      environment: environment,
      policy: policy
    )

    let ratio: Double
    switch environment {
    case .debug:
      ratio = samplingRatio ?? 1
    case .production:
      ratio = samplingRatio ?? 0.1
    }
    let sampler = Samplers.parentBased(root: Samplers.traceIdRatio(ratio: ratio))

    let rawSpanExporter: any SpanExporter
    switch environment {
    case .debug:
      rawSpanExporter = StdoutSpanExporter(isDebug: true)
    case .production:
      rawSpanExporter = StdoutSpanExporter(isDebug: false)
    }
    let spanExporter = PrivacyPreservingSpanExporter(
      exporter: rawSpanExporter,
      policy: policy
    )
    let spanProcessor = SimpleSpanProcessor(spanExporter: spanExporter)
    let spanLimits = SpanLimits()
      .settingAttributeCountLimit(16)
      .settingAttributeValueLengthLimit(
        UInt(TelemetryIdentifier<FeatureIdentifierKind>.maximumLength)
      )
      .settingEventCountLimit(4)
      .settingLinkCountLimit(0)
      .settingAttributePerEventCountLimit(8)
      .settingAttributePerLinkCountLimit(0)
    let tracerProvider = TracerProviderBuilder()
      .with(resource: resource)
      .with(spanLimits: spanLimits)
      .with(sampler: sampler)
      .add(spanProcessor: spanProcessor)
      .build()

    let rawMetricExporter: any MetricExporter
    switch environment {
    case .debug:
      rawMetricExporter = StdoutMetricExporter(isDebug: true)
    case .production:
      rawMetricExporter = StdoutMetricExporter(isDebug: false)
    }
    let metricExporter = PrivacyPreservingMetricExporter(
      exporter: rawMetricExporter,
      policy: policy
    )
    let metricInterval: TimeInterval
    switch environment {
    case .debug:
      metricInterval = 5
    case .production:
      metricInterval = 60
    }
    let metricReader = PeriodicMetricReaderBuilder(exporter: metricExporter)
      .setInterval(timeInterval: metricInterval)
      .build()
    let meterBuilder = MeterProviderSdk.builder()
      .setResource(resource: resource)
      .registerMetricReader(reader: metricReader)
    ComposableOTelMetricConfiguration.registerViews(on: meterBuilder, policy: policy)
    let meterProvider = meterBuilder.build()

    let rawLogExporter: any LogRecordExporter
    switch environment {
    case .debug:
      rawLogExporter = StdoutLogExporter(isDebug: true)
    case .production:
      rawLogExporter = StdoutLogExporter(isDebug: false)
    }
    let logExporter = PrivacyPreservingLogRecordExporter(
      exporter: rawLogExporter,
      policy: policy
    )
    let logProcessor = SimpleLogRecordProcessor(logRecordExporter: logExporter)
    let loggerProvider = LoggerProviderSdk(
      resource: resource,
      logRecordProcessors: [logProcessor]
    )

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

    return TelemetryClient.unsafeCustomSDK(
      tracer: tracer,
      metrics: ComposableOTelMetricConfiguration.makeInstruments(meter: meter),
      logger: logger,
      policy: policy
    )
  }

  static func makeResource(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID?,
    environment: Environment,
    policy: TelemetryPolicy
  ) -> Resource {
    let deploymentEnvironment: String
    switch environment {
    case .debug:
      deploymentEnvironment = "debug"
    case .production:
      deploymentEnvironment = "production"
    }

    var attributes: [String: AttributeValue] = [
      "service.name": .string(serviceName.rawValue),
      "deployment.environment.name": .string(deploymentEnvironment),
      "os.type": .string("darwin"),
    ]
    let resolvedVersion =
      serviceVersion?.rawValue
      ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    if let resolvedVersion {
      attributes["service.version"] = .string(resolvedVersion)
    }
    return Resource(attributes: policy.sanitizedResourceAttributes(attributes))
  }
}
