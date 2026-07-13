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
    private var shutdown: (() -> Void)?

    func configure(
      _ makeClient: () throws -> (client: TelemetryClient, shutdown: () -> Void)
    ) rethrows -> TelemetryClient {
      lock.lock()
      defer { lock.unlock() }
      if let client {
        return client
      }
      let configured = try makeClient()
      let client = configured.client
      self.client = client
      shutdown = configured.shutdown
      return client
    }

    func resetForTesting() {
      let shutdown = lock.withLock {
        let shutdown = self.shutdown
        client = nil
        self.shutdown = nil
        return shutdown
      }
      shutdown?()
    }
  }

  private static let state = State()
  package static func resetForTesting() {
    state.resetForTesting()
  }

  /// Configures development-only, bounded stdout telemetry once for the process.
  ///
  /// The first call owns the cached package client; OpenTelemetry process globals remain untouched.
  /// The policy controls each signal independently, and logs are disabled by default. Values
  /// outside the policy schema aggregate to `other`.
  @discardableResult
  public static func configure(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID? = nil,
    samplingRatio: Double? = nil,
    resourceMode: TelemetryResourceMode = .native(environment: .development),
    policy: TelemetryPolicy = .init()
  ) throws -> TelemetryClient {
    try state.configure {
      try makeClient(
        serviceName: serviceName,
        serviceVersion: serviceVersion,
        samplingRatio: samplingRatio,
        resourceMode: resourceMode,
        policy: policy
      )
    }
  }

  private static func makeClient(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID?,
    samplingRatio: Double?,
    resourceMode: TelemetryResourceMode,
    policy: TelemetryPolicy
  ) throws -> (client: TelemetryClient, shutdown: () -> Void) {
    let resource = try makeResource(
      serviceName: serviceName,
      serviceVersion: serviceVersion,
      resourceMode: resourceMode,
      policy: policy
    )

    let ratio = samplingRatio ?? 1
    let sampler = Samplers.parentBased(root: Samplers.traceIdRatio(ratio: ratio))

    let rawSpanExporter: any SpanExporter = StdoutSpanExporter(isDebug: true)
    let spanExporter = PrivacyPreservingSpanExporter(
      exporter: rawSpanExporter,
      policy: policy
    )
    let spanProcessor = SimpleSpanProcessor(spanExporter: spanExporter)
    let spanLimits = SpanLimits()
      .settingAttributeCountLimit(16)
      .settingAttributeValueLengthLimit(
        UInt(TelemetryStringValue.maximumLength)
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

    let rawMetricExporter: any MetricExporter = StdoutMetricExporter(isDebug: true)
    let metricExporter = PrivacyPreservingMetricExporter(
      exporter: rawMetricExporter,
      policy: policy
    )
    let metricReader = PeriodicMetricReaderBuilder(exporter: metricExporter)
      .setInterval(timeInterval: 5)
      .build()
    let meterBuilder = MeterProviderSdk.builder()
      .setResource(resource: resource)
      .registerMetricReader(reader: metricReader)
    ComposableOTelMetricConfiguration.registerViews(on: meterBuilder, policy: policy)
    let meterProvider = meterBuilder.build()
    let customMeterProvider: MeterProviderSdk?
    let contractCounters: [TelemetryContractIdentity: any LongCounter]
    if policy.catalog.counters.isEmpty {
      customMeterProvider = nil
      contractCounters = [:]
    } else {
      let rawCustomExporter: any MetricExporter = StdoutMetricExporter(isDebug: true)
      let customExporter = PrivacyPreservingMetricExporter(
        exporter: DeltaCounterMetricExporter(exporter: rawCustomExporter),
        policy: policy
      )
      let customReader = PeriodicMetricReaderBuilder(exporter: customExporter)
        .setInterval(timeInterval: 5)
        .build()
      let customBuilder = MeterProviderSdk.builder()
        .setResource(resource: resource)
        .registerMetricReader(reader: customReader)
      ComposableOTelMetricConfiguration.registerViews(on: customBuilder, policy: policy)
      let provider = customBuilder.build()
      let customMeter =
        provider
        .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
        .setInstrumentationVersion(instrumentationVersion: ComposableOTelMetadata.version)
        .build()
      customMeterProvider = provider
      contractCounters = ComposableOTelMetricConfiguration.makeContractInstruments(
        meter: customMeter,
        catalog: policy.catalog
      )
    }

    let rawLogExporter: any LogRecordExporter = StdoutLogExporter(isDebug: true)
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

    let client = TelemetryClient.packageSDK(
      tracer: tracer,
      metrics: ComposableOTelMetricConfiguration.makeInstruments(meter: meter),
      logger: logger,
      policy: policy,
      contractCounters: contractCounters,
      contractProviderRetention: customMeterProvider
    )
    return (
      client,
      {
        tracerProvider.shutdown()
        _ = meterProvider.shutdown()
        _ = customMeterProvider?.shutdown()
      }
    )
  }

  package static func makeResource(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID?,
    resourceMode: TelemetryResourceMode = .native(environment: .production),
    policy: TelemetryPolicy
  ) throws -> Resource {
    if case .strict(let resource) = resourceMode {
      guard policy.catalog.contains(resource.identity) else {
        throw TelemetryContractError.unregisteredDefinition
      }
      var attributes = resource.attributes
      attributes[TelemetryContractCatalog.contractVersionKey] = .int(
        policy.catalog.contractVersion.rawValue
      )
      return Resource(attributes: policy.sanitizedResourceAttributes(attributes))
    }

    guard case .native(let deploymentEnvironment) = resourceMode else {
      preconditionFailure("unknown resource mode")
    }
    var attributes: [String: AttributeValue] = [
      "service.name": .string(serviceName.rawValue),
      "deployment.environment.name": .string(deploymentEnvironment.rawValue),
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
