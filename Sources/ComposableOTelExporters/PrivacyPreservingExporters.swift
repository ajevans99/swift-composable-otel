import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Sanitizes span names, resources, attributes, events, links, and status before export.
public final class PrivacyPreservingSpanExporter: SpanExporter, @unchecked Sendable {
  private let exporter: any SpanExporter
  private let boundary: TelemetryPrivacyBoundary

  public init(exporter: any SpanExporter, policy: TelemetryPolicy) {
    self.exporter = exporter
    boundary = TelemetryPrivacyBoundary(policy: policy)
  }

  @discardableResult
  public func export(
    spans: [SpanData],
    explicitTimeout: TimeInterval?
  ) -> SpanExporterResultCode {
    exportSync(spans: spans, explicitTimeout: explicitTimeout)
  }

  private func exportSync(
    spans: [SpanData],
    explicitTimeout: TimeInterval?
  ) -> SpanExporterResultCode {
    exporter.export(
      spans: boundary.sanitizedSpans(spans),
      explicitTimeout: explicitTimeout
    )
  }

  public func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    flushSync(explicitTimeout: explicitTimeout)
  }

  public func shutdown(explicitTimeout: TimeInterval?) {
    shutdownSync(explicitTimeout: explicitTimeout)
  }

  private func flushSync(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    exporter.flush(explicitTimeout: explicitTimeout)
  }

  private func shutdownSync(explicitTimeout: TimeInterval?) {
    exporter.shutdown(explicitTimeout: explicitTimeout)
  }

  @discardableResult
  public func export(
    spans: [SpanData],
    explicitTimeout: TimeInterval?
  ) async -> SpanExporterResultCode {
    exportSync(spans: spans, explicitTimeout: explicitTimeout)
  }

  public func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
    flushSync(explicitTimeout: explicitTimeout)
  }

  public func shutdown(explicitTimeout: TimeInterval?) async {
    shutdownSync(explicitTimeout: explicitTimeout)
  }

}

/// Rebuilds log records from allowlisted bodies, resources, attributes, and event names.
public final class PrivacyPreservingLogRecordExporter: LogRecordExporter, @unchecked Sendable {
  private let exporter: any LogRecordExporter
  private let boundary: TelemetryPrivacyBoundary

  public init(exporter: any LogRecordExporter, policy: TelemetryPolicy) {
    self.exporter = exporter
    boundary = TelemetryPrivacyBoundary(policy: policy)
  }

  public func export(
    logRecords: [ReadableLogRecord],
    explicitTimeout: TimeInterval?
  ) -> ExportResult {
    exportSync(logRecords: logRecords, explicitTimeout: explicitTimeout)
  }

  private func exportSync(
    logRecords: [ReadableLogRecord],
    explicitTimeout: TimeInterval?
  ) -> ExportResult {
    exporter.export(
      logRecords: boundary.sanitizedLogs(logRecords),
      explicitTimeout: explicitTimeout
    )
  }

  public func shutdown(explicitTimeout: TimeInterval?) {
    shutdownSync(explicitTimeout: explicitTimeout)
  }

  public func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    forceFlushSync(explicitTimeout: explicitTimeout)
  }

  private func shutdownSync(explicitTimeout: TimeInterval?) {
    exporter.shutdown(explicitTimeout: explicitTimeout)
  }

  private func forceFlushSync(explicitTimeout: TimeInterval?) -> ExportResult {
    exporter.forceFlush(explicitTimeout: explicitTimeout)
  }

  public func export(
    logRecords: [ReadableLogRecord],
    explicitTimeout: TimeInterval?
  ) async -> ExportResult {
    exportSync(logRecords: logRecords, explicitTimeout: explicitTimeout)
  }

  public func shutdown(explicitTimeout: TimeInterval?) async {
    shutdownSync(explicitTimeout: explicitTimeout)
  }

  public func forceFlush(explicitTimeout: TimeInterval?) async -> ExportResult {
    forceFlushSync(explicitTimeout: explicitTimeout)
  }

}

/// Drops unknown instruments and sanitizes package metric dimensions immediately before export.
public final class PrivacyPreservingMetricExporter: MetricExporter, @unchecked Sendable {
  private let exporter: any MetricExporter
  private let boundary: TelemetryPrivacyBoundary

  public init(exporter: any MetricExporter, policy: TelemetryPolicy) {
    self.exporter = exporter
    boundary = TelemetryPrivacyBoundary(policy: policy)
  }

  public func export(metrics: [MetricData]) -> ExportResult {
    exportSync(metrics: metrics)
  }

  private func exportSync(metrics: [MetricData]) -> ExportResult {
    exporter.export(metrics: boundary.sanitizedMetrics(metrics))
  }

  public func flush() -> ExportResult {
    flushSync()
  }

  public func shutdown() -> ExportResult {
    shutdownSync()
  }

  private func flushSync() -> ExportResult {
    exporter.flush()
  }

  private func shutdownSync() -> ExportResult {
    exporter.shutdown()
  }

  public func export(metrics: [MetricData]) async -> ExportResult {
    exportSync(metrics: metrics)
  }

  public func flush() async -> ExportResult {
    flushSync()
  }

  public func shutdown() async -> ExportResult {
    shutdownSync()
  }

  public func getAggregationTemporality(
    for instrument: InstrumentType
  ) -> AggregationTemporality {
    exporter.getAggregationTemporality(for: instrument)
  }

  public func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation {
    exporter.getDefaultAggregation(for: instrument)
  }

}

struct TelemetryPrivacyBoundary: Sendable {
  let policy: TelemetryPolicy

  func sanitizedSpans(_ spans: [SpanData]) -> [SpanData] {
    guard policy.signals.tracesEnabled else { return [] }
    return spans.filter { isSafeInstrumentationScope($0.instrumentationScope) }.map { original in
      var span = original
      let events = original.events.compactMap { event -> SpanData.Event? in
        guard let name = policy.sanitizedEventName(event.name) else { return nil }
        return SpanData.Event(
          name: name,
          timestamp: event.timestamp,
          attributes: policy.sanitizedSpanAttributes(event.attributes)
        )
      }
      let status: Status
      switch original.status {
      case .error:
        status = .error(description: "Operation failed")
      case .ok:
        status = .ok
      case .unset:
        status = .unset
      }
      span.settingName(policy.sanitizedSpanName(original.name))
      span.settingAttributes(policy.sanitizedSpanAttributes(original.attributes))
      span.settingEvents(events)
      span.settingLinks([])
      span.settingStatus(status)
      span.settingResource(
        Resource(
          attributes: policy.sanitizedResourceAttributes(original.resource.attributes)
        )
      )
      return span
    }
  }

  func sanitizedLogs(_ records: [ReadableLogRecord]) -> [ReadableLogRecord] {
    guard policy.signals.logsEnabled else { return [] }
    return records.map { record in
      ReadableLogRecord(
        resource: Resource(
          attributes: policy.sanitizedResourceAttributes(record.resource.attributes)
        ),
        instrumentationScopeInfo: safeInstrumentationScope,
        timestamp: record.timestamp,
        observedTimestamp: record.observedTimestamp,
        spanContext: record.spanContext,
        severity: record.severity,
        body: policy.sanitizedLogBody(record.body),
        attributes: policy.sanitizedLogAttributes(record.attributes),
        eventName: record.eventName.flatMap(policy.sanitizedEventName)
      )
    }
  }

  func sanitizedMetrics(_ metrics: [MetricData]) -> [MetricData] {
    guard policy.signals.metricsEnabled else { return [] }
    return metrics.compactMap { metric -> MetricData? in
      guard ComposableOTelSemantics.Metrics.all.contains(metric.name),
        isSafeInstrumentationScope(metric.instrumentationScopeInfo),
        metric.resource.attributes
          == policy.sanitizedResourceAttributes(metric.resource.attributes)
      else {
        return nil
      }
      for point in metric.data.points {
        point.attributes = policy.sanitizedMetricAttributes(
          point.attributes,
          instrumentName: metric.name
        )
        point.exemplars = []
      }
      return metric
    }
  }
}

private let safeInstrumentationScope = InstrumentationScopeInfo(
  name: ComposableOTelMetadata.instrumentationName,
  version: ComposableOTelMetadata.version
)

private func isSafeInstrumentationScope(_ scope: InstrumentationScopeInfo) -> Bool {
  scope.name == ComposableOTelMetadata.instrumentationName
    && scope.version == ComposableOTelMetadata.version
    && scope.schemaUrl == nil
    && (scope.attributes?.isEmpty ?? true)
}
