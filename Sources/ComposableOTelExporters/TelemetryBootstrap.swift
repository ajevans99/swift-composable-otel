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
    private var forceFlush: (() -> Void)?
    private var shutdown: (() -> Void)?

    func configure(
      _ makeClient: () throws -> (
        client: TelemetryClient,
        forceFlush: () -> Void,
        shutdown: () -> Void
      )
    ) rethrows -> TelemetryClient {
      lock.lock()
      defer { lock.unlock() }
      if let client {
        return client
      }
      let configured = try makeClient()
      let client = configured.client
      self.client = client
      forceFlush = configured.forceFlush
      shutdown = configured.shutdown
      return client
    }

    func forceFlushForTesting() {
      let forceFlush = lock.withLock { self.forceFlush }
      forceFlush?()
    }

    func resetForTesting() {
      let shutdown = lock.withLock {
        let shutdown = self.shutdown
        client = nil
        forceFlush = nil
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
  package static func forceFlushForTesting() {
    state.forceFlushForTesting()
  }

  /// Configures development-only, bounded stdout telemetry once for the process.
  ///
  /// The first call owns the cached package client; OpenTelemetry process globals remain untouched.
  /// The policy controls each signal independently, and logs are disabled by default. Values
  /// outside the policy schema aggregate to `other`. Optional observers receive only
  /// policy-sanitized values and do not replace stdout export.
  @discardableResult
  public static func configure(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID? = nil,
    samplingRatio: Double? = nil,
    resourceMode: TelemetryResourceMode = .native(environment: .development),
    policy: TelemetryPolicy = .init()
  ) throws -> TelemetryClient {
    try configure(
      serviceName: serviceName,
      serviceVersion: serviceVersion,
      samplingRatio: samplingRatio,
      resourceMode: resourceMode,
      policy: policy,
      observerExporters: .init()
    )
  }

  /// Configures development stdout plus independent, privacy-sanitized observer exporters.
  @discardableResult
  public static func configure(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID? = nil,
    samplingRatio: Double? = nil,
    resourceMode: TelemetryResourceMode = .native(environment: .development),
    policy: TelemetryPolicy = .init(),
    observerExporters: TelemetryObserverExporters
  ) throws -> TelemetryClient {
    try state.configure {
      try makeClient(
        serviceName: serviceName,
        serviceVersion: serviceVersion,
        samplingRatio: samplingRatio,
        resourceMode: resourceMode,
        policy: policy,
        observerExporters: observerExporters
      )
    }
  }

  private static func makeClient(
    serviceName: ServiceID,
    serviceVersion: ServiceVersionID?,
    samplingRatio: Double?,
    resourceMode: TelemetryResourceMode,
    policy: TelemetryPolicy,
    observerExporters: TelemetryObserverExporters
  ) throws -> (client: TelemetryClient, forceFlush: () -> Void, shutdown: () -> Void) {
    let resource = try makeResource(
      serviceName: serviceName,
      serviceVersion: serviceVersion,
      resourceMode: resourceMode,
      policy: policy
    )

    let ratio = samplingRatio ?? 1
    let sampler = Samplers.parentBased(root: Samplers.traceIdRatio(ratio: ratio))
    let observerPipeline = TelemetryObserverPipeline(
      exporters: observerExporters,
      policy: policy
    )

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
    let tracerBuilder = TracerProviderBuilder()
      .with(resource: resource)
      .with(spanLimits: spanLimits)
      .with(sampler: sampler)
      .add(spanProcessor: spanProcessor)
    for processor in observerPipeline.spanProcessors {
      _ = tracerBuilder.add(spanProcessor: processor)
    }
    let tracerProvider = tracerBuilder.build()

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
    observerPipeline.registerMetricReaders(on: meterBuilder, interval: 5)
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
      observerPipeline.registerMetricReaders(
        on: customBuilder,
        interval: 5,
        forceDeltaCounters: true
      )
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
      logRecordProcessors: [logProcessor as any LogRecordProcessor]
        + observerPipeline.logRecordProcessors
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
        tracerProvider.forceFlush()
        _ = meterProvider.forceFlush()
        _ = customMeterProvider?.forceFlush()
        _ = logProcessor.forceFlush()
        observerPipeline.forceFlushLogs(explicitTimeout: nil)
        observerPipeline.forceFlushMetrics()
      },
      {
        tracerProvider.shutdown()
        _ = meterProvider.shutdown()
        _ = customMeterProvider?.shutdown()
        _ = logProcessor.shutdown()
        observerPipeline.shutdownLogs(explicitTimeout: nil)
        observerPipeline.shutdownMetrics()
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
