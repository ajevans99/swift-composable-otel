import ComposableOTel
import ComposableOTelExporters
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// In-memory collectors returned by
/// ``ComposableOTel/TelemetryClient/test(metricReader:contractMetricReader:resourceMode:policy:)``.
public struct TestCollectors: @unchecked Sendable {
  public let spans: InMemorySpanCollector
  public let logs: InMemoryLogCollector
  public let metrics: InMemoryMetricReader?
  public let contractMetrics: InMemoryMetricReader?

  private let tracerProvider: TracerProviderSdk
  private let meterProvider: MeterProviderSdk
  private let contractMeterProvider: MeterProviderSdk?
  private let tailSampling: RuntimeTailSamplingCoordinator?

  init(
    spans: InMemorySpanCollector,
    logs: InMemoryLogCollector,
    metrics: InMemoryMetricReader?,
    contractMetrics: InMemoryMetricReader?,
    tracerProvider: TracerProviderSdk,
    meterProvider: MeterProviderSdk,
    contractMeterProvider: MeterProviderSdk?,
    tailSampling: RuntimeTailSamplingCoordinator?
  ) {
    self.spans = spans
    self.logs = logs
    self.metrics = metrics
    self.contractMetrics = contractMetrics
    self.tracerProvider = tracerProvider
    self.meterProvider = meterProvider
    self.contractMeterProvider = contractMeterProvider
    self.tailSampling = tailSampling
  }

  /// Flushes pending spans and metrics before assertions.
  public func forceFlush() {
    tailSampling?.forceFlush()
    tracerProvider.forceFlush()
    _ = meterProvider.forceFlush()
    _ = contractMeterProvider?.forceFlush()
  }

  /// Current sanitized, memory-only tail-retention usage.
  public var tailSamplingState: TestTailSamplingState? {
    tailSampling.map {
      let snapshot = $0.snapshot
      return TestTailSamplingState(
        retainedTraceCount: snapshot.retainedTraceCount,
        retainedSpanCount: snapshot.retainedSpanCount,
        retainedBreadcrumbCount: snapshot.retainedBreadcrumbCount,
        retainedByteEstimate: snapshot.retainedByteEstimate
      )
    }
  }
}

/// Bounded tail-retention usage exposed for deterministic tests.
public struct TestTailSamplingState: Equatable, Sendable {
  public let retainedTraceCount: Int
  public let retainedSpanCount: Int
  public let retainedBreadcrumbCount: Int
  public let retainedByteEstimate: Int
}

extension TelemetryClient {
  /// Creates an isolated test client with the same privacy boundary and metric views as bootstrap.
  public static func test(
    metricReader: InMemoryMetricReader? = nil,
    contractMetricReader: InMemoryMetricReader? = nil,
    resourceMode: TelemetryResourceMode = .native(environment: .test),
    policy: TelemetryPolicy = .init()
  ) throws -> (client: TelemetryClient, collectors: TestCollectors) {
    try test(
      samplingRatio: 1,
      tailSampling: .disabled,
      metricReader: metricReader,
      contractMetricReader: contractMetricReader,
      resourceMode: resourceMode,
      policy: policy
    )
  }

  /// Creates an isolated client with production-equivalent head and bounded tail sampling.
  public static func test(
    samplingRatio: Double,
    tailSampling: TelemetryTailSamplingConfiguration,
    metricReader: InMemoryMetricReader? = nil,
    contractMetricReader: InMemoryMetricReader? = nil,
    resourceMode: TelemetryResourceMode = .native(environment: .test),
    policy: TelemetryPolicy = .init()
  ) throws -> (client: TelemetryClient, collectors: TestCollectors) {
    guard samplingRatio.isFinite, (0...1).contains(samplingRatio) else {
      throw TelemetryRuntimeConfigurationError.invalidSamplingRatio
    }
    let resource = try TelemetryBootstrap.makeResource(
      serviceName: "test-suite",
      serviceVersion: nil,
      resourceMode: resourceMode,
      policy: policy
    )

    let spanCollector = InMemorySpanCollector()
    let logCollector = InMemoryLogCollector()
    let boundary = TelemetryPrivacyBoundary(policy: policy)
    let tailSampling = tailSampling.policy.map { tailPolicy in
      RuntimeTailSamplingCoordinator(
        policy: tailPolicy,
        samplingRatio: samplingRatio,
        clock: .live,
        emitSpans: { spans in
          spanCollector.export(spans: spans, explicitTimeout: nil) == .success
            ? .accepted : .dropped
        },
        emitLog: { record in
          logCollector.export(logRecords: [record], explicitTimeout: nil) == .success
            ? .accepted : .dropped
        }
      )
    }
    let tracerBuilder = TracerProviderBuilder()
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
    if let tailSampling {
      _ =
        tracerBuilder
        .with(sampler: RuntimeTailRecordingSampler())
        .add(
          spanProcessor: TestTailSpanProcessor(
            boundary: boundary,
            tailSampling: tailSampling
          )
        )
    } else {
      _ =
        tracerBuilder
        .with(
          sampler: Samplers.parentBased(
            root: Samplers.traceIdRatio(ratio: samplingRatio)
          )
        )
        .add(
          spanProcessor: SimpleSpanProcessor(
            spanExporter: PrivacyPreservingSpanExporter(
              exporter: spanCollector,
              policy: policy
            )
          )
        )
    }
    let tracerProvider = tracerBuilder.build()
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

    let logProcessor = TestPrivacyLogProcessor(
      boundary: boundary,
      collector: logCollector,
      tailSampling: tailSampling
    )
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
      contractProviderRetention: contractMeterProvider,
      tailPromotionRecorder: tailSampling.map {
        let tailSampling = $0
        return TelemetryTailPromotionRecorder { context in
          tailSampling.promote(context: context)
        }
      } ?? .disabled
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
        contractMeterProvider: contractMeterProvider,
        tailSampling: tailSampling
      )
    )
  }
}

private final class TestTailSpanProcessor: SpanProcessor, @unchecked Sendable {
  let isStartRequired = false
  let isEndRequired = true
  private let boundary: TelemetryPrivacyBoundary
  private let tailSampling: RuntimeTailSamplingCoordinator

  init(
    boundary: TelemetryPrivacyBoundary,
    tailSampling: RuntimeTailSamplingCoordinator
  ) {
    self.boundary = boundary
    self.tailSampling = tailSampling
  }

  func onStart(parentContext: SpanContext?, span: any ReadableSpan) {}

  func onEnd(span: any ReadableSpan) {
    guard let span = boundary.sanitizedSpans([span.toSpanData()]).first else { return }
    tailSampling.record(span: span)
  }

  func shutdown(explicitTimeout: TimeInterval?) {}

  func forceFlush(timeout: TimeInterval?) {
    tailSampling.forceFlush()
  }
}

private final class TestPrivacyLogProcessor: LogRecordProcessor, @unchecked Sendable {
  private let boundary: TelemetryPrivacyBoundary
  private let collector: InMemoryLogCollector
  private let tailSampling: RuntimeTailSamplingCoordinator?

  init(
    boundary: TelemetryPrivacyBoundary,
    collector: InMemoryLogCollector,
    tailSampling: RuntimeTailSamplingCoordinator?
  ) {
    self.boundary = boundary
    self.collector = collector
    self.tailSampling = tailSampling
  }

  func onEmit(logRecord: ReadableLogRecord) {
    guard let record = boundary.sanitizedLogs([logRecord]).first else { return }
    if let tailSampling {
      _ = tailSampling.record(log: record)
    } else {
      let record =
        record.spanContext?.traceFlags.sampled == false
        ? runtimeStrippingCorrelation(from: record)
        : record
      _ = collector.export(logRecords: [record], explicitTimeout: nil)
    }
  }

  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    tailSampling?.forceFlush()
    return .success
  }

  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    tailSampling?.shutdown(exportUncorrelatedErrors: false)
    return .success
  }
}
