import ComposableOTel
import Foundation
import OpenTelemetrySdk

/// Optional standard OpenTelemetry exporters that observe policy-sanitized package signals.
///
/// Each exporter is registered independently from stdout or OTLP export. Observer failures do not
/// suppress the package-owned export path. Exporters never receive values before `TelemetryPolicy`
/// has been applied.
///
/// Supplying an exporter transfers its lifecycle ownership to exactly one ``TelemetryBootstrap`` or
/// ``TelemetryRuntime`` pipeline. Do not reuse an exporter instance across separately configured
/// bootstrap or runtime lifetimes. Create fresh exporters that may share independently retained
/// stores instead.
public struct TelemetryObserverExporters: @unchecked Sendable {
  public let spanExporters: [any SpanExporter]
  public let logRecordExporters: [any LogRecordExporter]
  public let metricExporters: [any MetricExporter]

  public init(
    spanExporters: [any SpanExporter] = [],
    logRecordExporters: [any LogRecordExporter] = [],
    metricExporters: [any MetricExporter] = []
  ) {
    self.spanExporters = spanExporters
    self.logRecordExporters = logRecordExporters
    self.metricExporters = metricExporters
  }
}

struct TelemetryObserverPipeline: @unchecked Sendable {
  let spanProcessors: [any SpanProcessor]
  let logRecordProcessors: [any LogRecordProcessor]
  private let spanExporters: [PrivacyPreservingSpanExporter]
  private let metricLifecycles: [ObserverMetricExporterLifecycle]

  init(
    exporters: TelemetryObserverExporters,
    policy: TelemetryPolicy,
    metricExemplars: TelemetryMetricExemplarPolicy = .disabled,
    preserveErrorCorrelation: Bool = false
  ) {
    spanExporters = exporters.spanExporters.map {
      PrivacyPreservingSpanExporter(exporter: $0, policy: policy)
    }
    spanProcessors = spanExporters.map {
      SimpleSpanProcessor(spanExporter: $0)
    }
    logRecordProcessors = exporters.logRecordExporters.map {
      ObserverLogRecordProcessor(
        exporter: PrivacyPreservingLogRecordExporter(exporter: $0, policy: policy),
        preserveErrorCorrelation: preserveErrorCorrelation
      )
    }
    metricLifecycles = exporters.metricExporters.map {
      ObserverMetricExporterLifecycle(
        exporter: $0,
        policy: policy,
        metricExemplars: metricExemplars
      )
    }
  }

  func registerMetricReaders(
    on builder: MeterProviderBuilder,
    interval: TimeInterval,
    forceDeltaCounters: Bool = false
  ) {
    for lifecycle in metricLifecycles {
      let bridge = lifecycle.makeReaderExporter()
      let exporter: any MetricExporter =
        forceDeltaCounters
        ? DeltaCounterMetricExporter(exporter: bridge)
        : bridge
      let reader = PeriodicMetricReaderBuilder(exporter: exporter)
        .setInterval(timeInterval: interval)
        .build()
      _ = builder.registerMetricReader(reader: reader)
    }
  }

  func forceFlushLogs(explicitTimeout: TimeInterval?) {
    for processor in logRecordProcessors {
      _ = processor.forceFlush(explicitTimeout: explicitTimeout)
    }
  }

  func forceFlushSpans(explicitTimeout: TimeInterval?) {
    for processor in spanProcessors {
      processor.forceFlush(timeout: explicitTimeout)
    }
  }

  func emit(logRecord: ReadableLogRecord) {
    for processor in logRecordProcessors {
      processor.onEmit(logRecord: logRecord)
    }
  }

  func emit(spans: [SpanData]) {
    for exporter in spanExporters {
      _ = exporter.export(spans: spans, explicitTimeout: nil)
    }
  }

  func forceFlushMetrics() {
    for lifecycle in metricLifecycles {
      lifecycle.forceFlush()
    }
  }

  func shutdownLogs(explicitTimeout: TimeInterval?) {
    for processor in logRecordProcessors {
      _ = processor.shutdown(explicitTimeout: explicitTimeout)
    }
  }

  func shutdownSpans(explicitTimeout: TimeInterval?) {
    for var processor in spanProcessors {
      processor.shutdown(explicitTimeout: explicitTimeout)
    }
  }

  func shutdownMetrics() {
    for lifecycle in metricLifecycles {
      lifecycle.shutdown()
    }
  }
}

private final class ObserverLogRecordProcessor: LogRecordProcessor, @unchecked Sendable {
  private let lock = NSLock()
  private let exporter: PrivacyPreservingLogRecordExporter
  private let preserveErrorCorrelation: Bool
  private var isShutdown = false

  init(
    exporter: PrivacyPreservingLogRecordExporter,
    preserveErrorCorrelation: Bool
  ) {
    self.exporter = exporter
    self.preserveErrorCorrelation = preserveErrorCorrelation
  }

  func onEmit(logRecord: ReadableLogRecord) {
    lock.withLock {
      guard !isShutdown else { return }
      let record =
        !preserveErrorCorrelation && logRecord.severity == .error
          && logRecord.spanContext?.traceFlags.sampled == false
        ? runtimeStrippingCorrelation(from: logRecord)
        : logRecord
      _ = exporter.export(logRecords: [record], explicitTimeout: nil)
    }
  }

  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    lock.withLock {
      guard !isShutdown else { return .success }
      _ = exporter.forceFlush(explicitTimeout: explicitTimeout)
      return .success
    }
  }

  func shutdown(explicitTimeout: TimeInterval?) -> ExportResult {
    lock.withLock {
      guard !isShutdown else { return .success }
      isShutdown = true
      exporter.shutdown(explicitTimeout: explicitTimeout)
      return .success
    }
  }
}

private final class ObserverMetricExporterLifecycle: @unchecked Sendable {
  private let lock = NSLock()
  private let exporter: PrivacyPreservingMetricExporter
  private var isShutdown = false

  init(
    exporter: any MetricExporter,
    policy: TelemetryPolicy,
    metricExemplars: TelemetryMetricExemplarPolicy
  ) {
    self.exporter = PrivacyPreservingMetricExporter(
      exporter: exporter,
      policy: policy,
      metricExemplars: metricExemplars
    )
  }

  func makeReaderExporter() -> any MetricExporter {
    ObserverMetricReaderExporter(lifecycle: self)
  }

  func export(_ metrics: [MetricData]) {
    lock.withLock {
      guard !isShutdown else { return }
      _ = exporter.export(metrics: metrics)
    }
  }

  func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality {
    exporter.getAggregationTemporality(for: instrument)
  }

  func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation {
    exporter.getDefaultAggregation(for: instrument)
  }

  func forceFlush() {
    lock.withLock {
      guard !isShutdown else { return }
      _ = exporter.flush()
    }
  }

  func shutdown() {
    let shouldShutdown = lock.withLock {
      guard !isShutdown else { return false }
      isShutdown = true
      return true
    }
    guard shouldShutdown else { return }
    _ = exporter.shutdown()
  }
}

private final class ObserverMetricReaderExporter: MetricExporter, @unchecked Sendable {
  private let lifecycle: ObserverMetricExporterLifecycle

  init(lifecycle: ObserverMetricExporterLifecycle) {
    self.lifecycle = lifecycle
  }

  func export(metrics: [MetricData]) -> ExportResult {
    lifecycle.export(metrics)
    return .success
  }

  func flush() -> ExportResult {
    .success
  }

  func shutdown() -> ExportResult {
    .success
  }

  func getAggregationTemporality(
    for instrument: InstrumentType
  ) -> AggregationTemporality {
    lifecycle.getAggregationTemporality(for: instrument)
  }

  func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation {
    lifecycle.getDefaultAggregation(for: instrument)
  }
}
