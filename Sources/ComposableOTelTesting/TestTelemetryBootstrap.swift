import ComposableOTel
import ComposableOTelExporters
import OpenTelemetryApi
import OpenTelemetrySdk

/// In-memory collectors returned by
/// ``ComposableOTel/TelemetryClient/test(metricReader:contractMetricReader:deploymentEnvironment:resource:policy:)``.
public struct TestCollectors: @unchecked Sendable {
  public let spans: InMemorySpanCollector
  public let logs: InMemoryLogCollector
  public let metrics: InMemoryMetricReader?
  public let contractMetrics: InMemoryMetricReader?

  private let tracerProvider: TracerProviderSdk
  private let meterProvider: MeterProviderSdk
  private let contractMeterProvider: MeterProviderSdk?

  init(
    spans: InMemorySpanCollector,
    logs: InMemoryLogCollector,
    metrics: InMemoryMetricReader?,
    contractMetrics: InMemoryMetricReader?,
    tracerProvider: TracerProviderSdk,
    meterProvider: MeterProviderSdk,
    contractMeterProvider: MeterProviderSdk?
  ) {
    self.spans = spans
    self.logs = logs
    self.metrics = metrics
    self.contractMetrics = contractMetrics
    self.tracerProvider = tracerProvider
    self.meterProvider = meterProvider
    self.contractMeterProvider = contractMeterProvider
  }

  /// Flushes pending spans and metrics before assertions.
  public func forceFlush() {
    tracerProvider.forceFlush()
    _ = meterProvider.forceFlush()
    _ = contractMeterProvider?.forceFlush()
  }
}

extension TelemetryClient {
  /// Creates an isolated test client with the same privacy boundary and metric views as bootstrap.
  public static func test(
    metricReader: InMemoryMetricReader? = nil,
    contractMetricReader: InMemoryMetricReader? = nil,
    deploymentEnvironment: TelemetryDeploymentEnvironment = .test,
    resource: TelemetryResourceValue? = nil,
    policy: TelemetryPolicy = .init()
  ) -> (client: TelemetryClient, collectors: TestCollectors) {
    let resource = TelemetryBootstrap.makeResource(
      serviceName: "test-suite",
      serviceVersion: nil,
      deploymentEnvironment: deploymentEnvironment,
      resource: resource,
      policy: policy
    )

    let spanCollector = InMemorySpanCollector()
    let spanExporter = PrivacyPreservingSpanExporter(
      exporter: spanCollector,
      policy: policy
    )
    let spanProcessor = SimpleSpanProcessor(spanExporter: spanExporter)
    let tracerProvider = TracerProviderBuilder()
      .with(resource: resource)
      .with(
        spanLimits: SpanLimits()
          .settingAttributeCountLimit(16)
          .settingAttributeValueLengthLimit(
            UInt(TelemetryStringValue.maximumLength)
          )
          .settingEventCountLimit(4)
          .settingLinkCountLimit(0)
          .settingAttributePerEventCountLimit(8)
          .settingAttributePerLinkCountLimit(0)
      )
      .add(spanProcessor: spanProcessor)
      .build()
    let tracer = tracerProvider.get(
      instrumentationName: ComposableOTelMetadata.instrumentationName,
      instrumentationVersion: ComposableOTelMetadata.version
    )

    let registeredMetricReader = metricReader ?? InMemoryMetricReader()
    let meterBuilder = MeterProviderSdk.builder()
      .setResource(resource: resource)
      .registerMetricReader(reader: registeredMetricReader)
    ComposableOTelMetricConfiguration.registerViews(on: meterBuilder, policy: policy)
    let meterProvider = meterBuilder.build()
    let meter =
      meterProvider
      .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
      .setInstrumentationVersion(instrumentationVersion: ComposableOTelMetadata.version)
      .build()

    let resolvedContractReader: InMemoryMetricReader?
    let contractMeterProvider: MeterProviderSdk?
    let contractCounters: [TelemetryContractIdentity: any LongCounter]
    if policy.catalog.counters.isEmpty {
      resolvedContractReader = nil
      contractMeterProvider = nil
      contractCounters = [:]
    } else {
      let reader = contractMetricReader ?? InMemoryMetricReader(temporality: .delta)
      let contractBuilder = MeterProviderSdk.builder()
        .setResource(resource: resource)
        .registerMetricReader(reader: reader)
      ComposableOTelMetricConfiguration.registerViews(on: contractBuilder, policy: policy)
      let provider = contractBuilder.build()
      let contractMeter =
        provider
        .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
        .setInstrumentationVersion(instrumentationVersion: ComposableOTelMetadata.version)
        .build()
      resolvedContractReader = reader
      contractMeterProvider = provider
      contractCounters = ComposableOTelMetricConfiguration.makeContractInstruments(
        meter: contractMeter,
        catalog: policy.catalog
      )
    }

    let logCollector = InMemoryLogCollector()
    let logExporter = PrivacyPreservingLogRecordExporter(
      exporter: logCollector,
      policy: policy
    )
    let logProcessor = SimpleLogRecordProcessor(logRecordExporter: logExporter)
    let loggerProvider = LoggerProviderSdk(
      resource: resource,
      logRecordProcessors: [logProcessor]
    )
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
      contractProviderRetention: contractMeterProvider
    )
    return (
      client,
      TestCollectors(
        spans: spanCollector,
        logs: logCollector,
        metrics: metricReader,
        contractMetrics: resolvedContractReader,
        tracerProvider: tracerProvider,
        meterProvider: meterProvider,
        contractMeterProvider: contractMeterProvider
      )
    )
  }
}
