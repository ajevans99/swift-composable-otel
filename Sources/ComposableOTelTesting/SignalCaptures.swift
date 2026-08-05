import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Decoded registered host/session context from a sanitized signal.
public struct CapturedTelemetryHostContext: Equatable, Sendable {
  public let processSessionID: TelemetryProcessSessionID
  public let platform: TelemetryHostPlatform
  public let processKind: TelemetryHostProcessKind

  public init(
    processSessionID: TelemetryProcessSessionID,
    platform: TelemetryHostPlatform,
    processKind: TelemetryHostProcessKind
  ) {
    self.processSessionID = processSessionID
    self.platform = platform
    self.processKind = processKind
  }
}

public enum CapturedTelemetrySpanStatus: Equatable, Sendable {
  case unset
  case ok
  case error
}

public struct CapturedTelemetrySpanEvent: Equatable, Sendable {
  public let name: String
  public let metadata: [String: TelemetryDecodedScalar]
}

/// An SDK-independent, decoded span captured after the privacy boundary.
public struct CapturedTelemetrySpan: Equatable, Sendable {
  public let name: String
  public let traceID: String
  public let spanID: String
  public let parentSpanID: String?
  public let status: CapturedTelemetrySpanStatus
  public let metadata: [String: TelemetryDecodedScalar]
  public let events: [CapturedTelemetrySpanEvent]
  public let hostContext: CapturedTelemetryHostContext?
  public let durationMilliseconds: Double
}

/// One exact parent/child tree from captured sanitized spans.
public struct CapturedTelemetrySpanTree: Equatable, Sendable {
  public let span: CapturedTelemetrySpan
  public let children: [CapturedTelemetrySpanTree]
}

/// A stable tree shape for exact assertions without runtime-generated identifiers or durations.
public struct TelemetrySpanTreeExpectation: Equatable, Sendable {
  public let name: String
  public let children: [TelemetrySpanTreeExpectation]

  public init(
    _ name: String,
    children: [TelemetrySpanTreeExpectation] = []
  ) {
    self.name = name
    self.children = children
  }
}

/// An SDK-independent decoded log captured after the privacy boundary.
public struct CapturedTelemetryLogRecord: Equatable, Sendable {
  public let eventName: String?
  public let body: String?
  public let severity: TelemetryLogSeverity?
  public let metadata: [String: TelemetryDecodedScalar]
  public let hostContext: CapturedTelemetryHostContext?
  public let traceID: String?
  public let spanID: String?
}

extension InMemorySpanCollector {
  /// All spans decoded into package-owned test values in export order.
  public var capturedSpans: [CapturedTelemetrySpan] {
    spans.map(capturedSpan)
  }

  /// Exact captured trees ordered by root start time.
  public var spanTrees: [CapturedTelemetrySpanTree] {
    let source = spans
    let byParent = Dictionary(grouping: source) { $0.parentSpanId?.hexString }
    let knownIDs = Set(source.map { $0.spanId.hexString })
    let roots = source.filter {
      guard let parent = $0.parentSpanId?.hexString else { return true }
      return !knownIDs.contains(parent)
    }.sorted(by: spanOrder)

    func tree(_ span: SpanData) -> CapturedTelemetrySpanTree {
      CapturedTelemetrySpanTree(
        span: capturedSpan(span),
        children: (byParent[span.spanId.hexString] ?? []).sorted(by: spanOrder).map(tree)
      )
    }
    return roots.map(tree)
  }

  /// Stable tree shapes suitable for exact equality assertions.
  public var spanTreeExpectations: [TelemetrySpanTreeExpectation] {
    spanTrees.map(expectation)
  }
}

extension InMemoryLogCollector {
  /// All logs decoded into package-owned test values in export order.
  public var capturedRecords: [CapturedTelemetryLogRecord] {
    allRecords.map { record in
      CapturedTelemetryLogRecord(
        eventName: record.eventName,
        body: {
          guard case .string(let body) = record.body else { return nil }
          return body
        }(),
        severity: TelemetryLogSeverity(otelSeverity: record.severity),
        metadata: capturedMetadata(record.attributes),
        hostContext: capturedHostContext(record.attributes),
        traceID: record.spanContext?.traceId.hexString,
        spanID: record.spanContext?.spanId.hexString
      )
    }
  }
}

extension InMemoryMetricReader {
  /// Whether any collected metric point contains a registered host/session context key.
  public var containsHostContext: Bool {
    metrics.contains { metric in
      metric.data.points.contains { point in
        capturedHostContext(point.attributes) != nil
          || point.attributes.keys.contains(TCAAttributes.processSessionID)
          || point.attributes.keys.contains(TCAAttributes.hostPlatform)
          || point.attributes.keys.contains(TCAAttributes.hostProcessKind)
      }
    }
  }
}

package func capturedHostContext(
  _ attributes: [String: AttributeValue]
) -> CapturedTelemetryHostContext? {
  guard
    case .string(let session)? = attributes[TCAAttributes.processSessionID],
    let session = TelemetryProcessSessionID(validating: session),
    case .string(let platform)? = attributes[TCAAttributes.hostPlatform],
    let platform = TelemetryHostPlatform(rawValue: platform),
    case .string(let processKind)? = attributes[TCAAttributes.hostProcessKind],
    let processKind = TelemetryHostProcessKind(rawValue: processKind)
  else {
    return nil
  }
  return CapturedTelemetryHostContext(
    processSessionID: session,
    platform: platform,
    processKind: processKind
  )
}

private func capturedSpan(_ span: SpanData) -> CapturedTelemetrySpan {
  let status: CapturedTelemetrySpanStatus =
    switch span.status {
    case .unset: .unset
    case .ok: .ok
    case .error: .error
    }
  return CapturedTelemetrySpan(
    name: span.name,
    traceID: span.traceId.hexString,
    spanID: span.spanId.hexString,
    parentSpanID: span.parentSpanId?.hexString,
    status: status,
    metadata: capturedMetadata(span.attributes),
    events: span.events.map {
      CapturedTelemetrySpanEvent(
        name: $0.name,
        metadata: capturedMetadata($0.attributes)
      )
    },
    hostContext: capturedHostContext(span.attributes),
    durationMilliseconds: span.endTime.timeIntervalSince(span.startTime) * 1_000
  )
}

private func capturedMetadata(
  _ attributes: [String: AttributeValue]
) -> [String: TelemetryDecodedScalar] {
  var result: [String: TelemetryDecodedScalar] = [:]
  for (key, value) in attributes
  where key != TCAAttributes.processSessionID
    && key != TCAAttributes.hostPlatform
    && key != TCAAttributes.hostProcessKind
  {
    switch value {
    case .string(let value):
      result[key] = .string(value)
    case .int(let value):
      result[key] = .integer(value)
    case .double(let value):
      result[key] = .double(value)
    case .bool(let value):
      result[key] = .boolean(value)
    default:
      break
    }
  }
  return result
}

private func spanOrder(_ lhs: SpanData, _ rhs: SpanData) -> Bool {
  if lhs.startTime == rhs.startTime {
    return lhs.spanId.hexString < rhs.spanId.hexString
  }
  return lhs.startTime < rhs.startTime
}

private func expectation(_ tree: CapturedTelemetrySpanTree) -> TelemetrySpanTreeExpectation {
  TelemetrySpanTreeExpectation(
    tree.span.name,
    children: tree.children.map(expectation)
  )
}
