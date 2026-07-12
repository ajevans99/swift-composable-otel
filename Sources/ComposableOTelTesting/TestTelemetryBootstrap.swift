import ComposableOTel
import ComposableOTelExporters
import OpenTelemetryApi
import OpenTelemetrySdk

/// In-memory collectors returned by ``ComposableOTel/TelemetryClient/test(metricReader:policy:)``.
public struct TestCollectors: @unchecked Sendable {
  public let spans: InMemorySpanCollector
  public let logs: InMemoryLogCollector
  public let metrics: InMemoryMetricReader?

  private let tracerProvider: TracerProviderSdk
  private let meterProvider: MeterProviderSdk

  init(
    spans: InMemorySpanCollector,
    logs: InMemoryLogCollector,
    metrics: InMemoryMetricReader?,
    tracerProvider: TracerProviderSdk,
    meterProvider: MeterProviderSdk
  ) {
    self.spans = spans
    self.logs = logs
    self.metrics = metrics
    self.tracerProvider = tracerProvider
    self.meterProvider = meterProvider
  }

  /// Flushes pending spans and metrics before assertions.
  public func forceFlush() {
    tracerProvider.forceFlush()
    _ = meterProvider.forceFlush()
  }
}

extension TelemetryClient {
  /// Creates an isolated test client with the same privacy boundary and metric views as bootstrap.
  public static func test(
    metricReader: InMemoryMetricReader? = nil,
    policy: TelemetryPolicy = .init()
  ) -> (client: TelemetryClient, collectors: TestCollectors) {
    let resource = Resource(
      attributes: policy.sanitizedResourceAttributes([
        "service.name": .string("test-suite")
      ])
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
            UInt(TelemetryIdentifier<FeatureIdentifierKind>.maximumLength)
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

    let client = TelemetryClient.unsafeCustomSDK(
      tracer: tracer,
      metrics: ComposableOTelMetricConfiguration.makeInstruments(meter: meter),
      logger: logger,
      policy: policy
    )
    return (
      client,
      TestCollectors(
        spans: spanCollector,
        logs: logCollector,
        metrics: metricReader,
        tracerProvider: tracerProvider,
        meterProvider: meterProvider
      )
    )
  }
}
