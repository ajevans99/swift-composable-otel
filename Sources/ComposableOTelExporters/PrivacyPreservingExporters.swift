import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Sanitizes span names, resources, attributes, events, links, and status before export.
package final class PrivacyPreservingSpanExporter: SpanExporter, @unchecked Sendable {
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
package final class PrivacyPreservingLogRecordExporter: LogRecordExporter, @unchecked Sendable {
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
    let records = boundary.sanitizedLogs(logRecords).map { record in
      if record.severity == .error, record.spanContext?.traceFlags.sampled == false {
        return runtimeStrippingCorrelation(from: record)
      }
      return record
    }
    return exporter.export(
      logRecords: records,
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
package final class PrivacyPreservingMetricExporter: MetricExporter, @unchecked Sendable {
  private let exporter: any MetricExporter
  private let boundary: TelemetryPrivacyBoundary

  public init(
    exporter: any MetricExporter,
    policy: TelemetryPolicy,
    metricExemplars: TelemetryMetricExemplarPolicy = .disabled
  ) {
    self.exporter = exporter
    boundary = TelemetryPrivacyBoundary(policy: policy, metricExemplars: metricExemplars)
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

package final class DeltaCounterMetricExporter: MetricExporter, @unchecked Sendable {
  private let exporter: any MetricExporter

  package init(exporter: any MetricExporter) {
    self.exporter = exporter
  }

  package func export(metrics: [MetricData]) -> ExportResult {
    exporter.export(metrics: metrics)
  }

  package func flush() -> ExportResult {
    exporter.flush()
  }

  package func shutdown() -> ExportResult {
    exporter.shutdown()
  }

  package func getAggregationTemporality(
    for instrument: InstrumentType
  ) -> AggregationTemporality {
    instrument == .counter ? .delta : exporter.getAggregationTemporality(for: instrument)
  }

  package func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation {
    exporter.getDefaultAggregation(for: instrument)
  }
}

package struct TelemetryPrivacyBoundary: Sendable {
  package let policy: TelemetryPolicy
  package let metricExemplars: TelemetryMetricExemplarPolicy

  package init(
    policy: TelemetryPolicy,
    metricExemplars: TelemetryMetricExemplarPolicy = .disabled
  ) {
    self.policy = policy
    self.metricExemplars = metricExemplars
  }

  package func sanitizedSpans(_ spans: [SpanData]) -> [SpanData] {
    guard policy.signals.tracesEnabled else { return [] }
    return spans.filter { isSafeInstrumentationScope($0.instrumentationScope) }.compactMap {
      original in
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
      let name: String
      let signalAttributes: [String: AttributeValue]
      let originalAttributes = policy.removingHostContext(from: original.attributes)
      if let schema = policy.catalog.spans[original.name] {
        guard
          let sanitized = schema.sanitizedAttributes(
            originalAttributes,
            version: policy.catalog.contractVersion
          )
        else {
          return nil
        }
        name = original.name
        signalAttributes = sanitized
      } else {
        name = policy.sanitizedSpanName(original.name)
        signalAttributes = policy.sanitizedSpanAttributes(originalAttributes)
      }
      guard let attributes = policy.addingValidatedHostContext(to: signalAttributes) else {
        return nil
      }
      span.settingName(name)
      span.settingAttributes(attributes)
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

  package func sanitizedLogs(_ records: [ReadableLogRecord]) -> [ReadableLogRecord] {
    records.compactMap { record in
      if let eventName = record.eventName,
        let schema =
          policy.catalog.operationalEvents[eventName] ?? policy.catalog.logs[eventName]
      {
        let isOperationalEvent = policy.catalog.operationalEvents[eventName] != nil
        let enabled: Bool
        if isOperationalEvent {
          enabled = policy.signals.operationalEventsEnabled
        } else if let severity = schema.severity {
          enabled = policy.shouldRecordLog(
            severity: severity,
            stableIdentifier: eventName
          )
        } else {
          enabled = false
        }
        guard
          enabled,
          isSafeInstrumentationScope(record.instrumentationScopeInfo),
          record.severity == schema.severity?.otelSeverity,
          (schema.bodyIsNil && record.body == nil)
            || (!schema.bodyIsNil && record.body == schema.fixedBody),
          let attributes = schema.sanitizedAttributes(
            policy.removingHostContext(from: record.attributes),
            version: policy.catalog.contractVersion
          ),
          let attributes = policy.addingValidatedHostContext(to: attributes)
        else {
          return nil
        }
        return ReadableLogRecord(
          resource: Resource(
            attributes: policy.sanitizedResourceAttributes(record.resource.attributes)
          ),
          instrumentationScopeInfo: safeInstrumentationScope,
          timestamp: record.timestamp,
          observedTimestamp: record.observedTimestamp,
          spanContext: record.spanContext,
          severity: schema.severity?.otelSeverity,
          body: schema.fixedBody,
          attributes: attributes,
          eventName: eventName
        )
      }
      if record.eventName == TelemetryLogWireFormat.eventName {
        guard
          isSafeInstrumentationScope(record.instrumentationScopeInfo),
          let severity = TelemetryLogSeverity(otelSeverity: record.severity),
          let sanitized = TelemetryLogWireFormat.sanitize(
            body: record.body,
            attributes: policy.removingHostContext(from: record.attributes),
            policy: policy
          ),
          case .string(let templateID) = sanitized.attributes[
            TelemetryLogWireFormat.templateIDKey
          ],
          policy.shouldRecordLog(
            severity: severity,
            stableIdentifier: templateID
          ),
          let attributes = policy.addingValidatedHostContext(to: sanitized.attributes)
        else {
          return nil
        }
        return ReadableLogRecord(
          resource: Resource(
            attributes: policy.sanitizedResourceAttributes(record.resource.attributes)
          ),
          instrumentationScopeInfo: safeInstrumentationScope,
          timestamp: record.timestamp,
          observedTimestamp: record.observedTimestamp,
          spanContext: record.spanContext,
          severity: severity.otelSeverity,
          body: sanitized.body,
          attributes: attributes,
          eventName: TelemetryLogWireFormat.eventName
        )
      }
      guard
        let severity = TelemetryLogSeverity(otelSeverity: record.severity)
      else {
        return nil
      }
      let body = policy.sanitizedLogBody(record.body)
      let stableIdentifier =
        record.eventName.flatMap(policy.sanitizedEventName)
        ?? body.description
      guard
        policy.shouldRecordLog(
          severity: severity,
          stableIdentifier: stableIdentifier
        ),
        let attributes = policy.addingValidatedHostContext(
          to: policy.sanitizedLogAttributes(
            policy.removingHostContext(from: record.attributes)
          )
        )
      else {
        return nil
      }
      return ReadableLogRecord(
        resource: Resource(
          attributes: policy.sanitizedResourceAttributes(record.resource.attributes)
        ),
        instrumentationScopeInfo: safeInstrumentationScope,
        timestamp: record.timestamp,
        observedTimestamp: record.observedTimestamp,
        spanContext: record.spanContext,
        severity: severity.otelSeverity,
        body: body,
        attributes: attributes,
        eventName: record.eventName.flatMap(policy.sanitizedEventName)
      )
    }
  }

  package func sanitizedMetrics(_ metrics: [MetricData]) -> [MetricData] {
    guard policy.signals.metricsEnabled else { return [] }
    return metrics.compactMap { metric -> MetricData? in
      guard isSafeInstrumentationScope(metric.instrumentationScopeInfo),
        metric.resource.attributes
          == policy.sanitizedResourceAttributes(metric.resource.attributes)
      else {
        return nil
      }
      if let schema = policy.catalog.counters[metric.name] {
        guard
          metric.type == .LongSum,
          metric.isMonotonic,
          metric.unit == schema.unit,
          metric.data.aggregationTemporality == .delta
        else {
          return nil
        }
        for point in metric.data.points {
          guard
            let attributes = schema.sanitizedAttributes(
              point.attributes,
              version: policy.catalog.contractVersion
            )
          else {
            return nil
          }
          point.attributes = attributes
          point.exemplars = sanitizedExemplars(point.exemplars)
        }
        return metric
      }
      guard ComposableOTelSemantics.Metrics.all.contains(metric.name) else {
        return nil
      }
      for point in metric.data.points {
        point.attributes = policy.sanitizedMetricAttributes(
          point.attributes,
          instrumentName: metric.name
        )
        point.exemplars = sanitizedExemplars(point.exemplars)
      }
      return metric
    }
  }

  private func sanitizedExemplars(_ exemplars: [ExemplarData]) -> [ExemplarData] {
    let maximum = metricExemplars.maximumPerDataPoint
    guard maximum > 0 else { return [] }

    var selected: [ExemplarData] = []
    selected.reserveCapacity(maximum)
    for exemplar in exemplars {
      guard let context = exemplar.spanContext, context.isValid else { continue }
      exemplar.filteredAttributes = [:]

      let insertionIndex =
        selected.firstIndex { exemplarRanksBefore(exemplar, $0) } ?? selected.endIndex
      if insertionIndex < maximum {
        selected.insert(exemplar, at: insertionIndex)
        if selected.count > maximum {
          selected.removeLast()
        }
      }
    }
    return selected
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

private func exemplarRanksBefore(_ lhs: ExemplarData, _ rhs: ExemplarData) -> Bool {
  if lhs.epochNanos != rhs.epochNanos {
    return lhs.epochNanos > rhs.epochNanos
  }
  guard let lhsContext = lhs.spanContext, let rhsContext = rhs.spanContext else {
    return false
  }
  if lhsContext.traceId != rhsContext.traceId {
    return lhsContext.traceId < rhsContext.traceId
  }
  return lhsContext.spanId < rhsContext.spanId
}
