import ComposableOTel
import ComposableOTelExporters
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

public enum TelemetryDecodedScalar: Equatable, Sendable {
  case string(String)
  case integer(Int)
  case double(Double)
  case boolean(Bool)
}

public struct DecodedContractSpan: Equatable, Sendable {
  public let name: String
  public let contractVersion: Int
  public let fields: [String: TelemetryDecodedScalar]
}

public struct DecodedContractLog: Equatable, Sendable {
  public let eventName: String
  public let severity: TelemetryLogSeverity
  public let body: TelemetryDecodedScalar?
  public let contractVersion: Int
  public let fields: [String: TelemetryDecodedScalar]
}

public struct DecodedOperationalEvent: Equatable, Sendable {
  public let eventName: String
  public let contractVersion: Int
  public let fields: [String: TelemetryDecodedScalar]
}

public enum TelemetryDecodedTemporality: Equatable, Sendable {
  case delta
  case cumulative
}

public struct DecodedContractCounter: Equatable, Sendable {
  public let name: String
  public let unit: String
  public let isMonotonic: Bool
  public let temporality: TelemetryDecodedTemporality
  public let value: Int
  public let contractVersion: Int
  public let fields: [String: TelemetryDecodedScalar]
}

public struct DecodedContractResource: Equatable, Sendable {
  public let contractVersion: Int
  public let fields: [String: TelemetryDecodedScalar]
}

public struct EncodedTelemetryRequest: Equatable, Sendable {
  public let signal: TelemetryRuntimeSignal?
  public let body: Data
  public let contentType: String?
}

public final class InMemoryEncodedRequestCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [EncodedTelemetryRequest] = []

  public init() {}

  public var requests: [EncodedTelemetryRequest] {
    lock.withLock { storage }
  }

  public var transport: TelemetryHTTPTransport {
    TelemetryHTTPTransport { [weak self] request in
      guard let self else { throw CancellationError() }
      let signal: TelemetryRuntimeSignal?
      switch request.url?.lastPathComponent {
      case "traces": signal = .traces
      case "metrics": signal = .metrics
      case "logs": signal = .logs
      default: signal = nil
      }
      let captured = EncodedTelemetryRequest(
        signal: signal,
        body: request.httpBody ?? Data(),
        contentType: request.value(forHTTPHeaderField: "Content-Type")
      )
      self.lock.withLock {
        self.storage.append(captured)
      }
      return TelemetryHTTPResponse(statusCode: 202)
    }
  }

  public func reset() {
    lock.withLock {
      storage.removeAll()
    }
  }
}

extension TestCollectors {
  public func decodedSpans<Payload>(
    for definition: TelemetrySpanDefinition<Payload>
  ) -> [DecodedContractSpan] {
    spans.spans.compactMap { span in
      guard span.name == definition.name.rawValue else { return nil }
      return decodeRecord(span.attributes).map {
        DecodedContractSpan(
          name: span.name,
          contractVersion: $0.version,
          fields: $0.fields
        )
      }
    }
  }

  public func decodedLogs<Payload>(
    for definition: TelemetryLogDefinition<Payload>
  ) -> [DecodedContractLog] {
    logs.allRecords.compactMap { record in
      guard record.eventName == definition.eventName.rawValue,
        let severity = decodedContractLogSeverity(record.severity),
        let decoded = decodeRecord(record.attributes)
      else {
        return nil
      }
      return DecodedContractLog(
        eventName: record.eventName ?? definition.eventName.rawValue,
        severity: severity,
        body: record.body.flatMap(decodeScalar),
        contractVersion: decoded.version,
        fields: decoded.fields
      )
    }
  }

  /// Returns exact accepted values for a registered operational event in recording order.
  public func decodedOperationalEvents<Payload>(
    for definition: TelemetryOperationalEventDefinition<Payload>
  ) -> [DecodedOperationalEvent] {
    logs.allRecords.compactMap { record in
      guard
        record.eventName == definition.eventName.rawValue,
        record.severity == .info,
        record.body == nil,
        let decoded = decodeRecord(record.attributes)
      else {
        return nil
      }
      return DecodedOperationalEvent(
        eventName: definition.eventName.rawValue,
        contractVersion: decoded.version,
        fields: decoded.fields
      )
    }
  }

  public func decodedCounters<Payload>(
    for definition: TelemetryCounterDefinition<Payload>
  ) -> [DecodedContractCounter] {
    guard let contractMetrics else { return [] }
    return contractMetrics.metrics(named: definition.name.rawValue).flatMap { metric in
      metric.data.points.compactMap { point in
        guard let point = point as? LongPointData,
          let decoded = decodeRecord(point.attributes)
        else {
          return nil
        }
        return DecodedContractCounter(
          name: metric.name,
          unit: metric.unit,
          isMonotonic: metric.isMonotonic,
          temporality: metric.data.aggregationTemporality == .delta ? .delta : .cumulative,
          value: point.value,
          contractVersion: decoded.version,
          fields: decoded.fields
        )
      }
    }
  }

  public func decodedResource<Payload>(
    for definition: TelemetryResourceDefinition<Payload>
  ) -> DecodedContractResource? {
    let resources =
      spans.spans.map(\.resource)
      + logs.allRecords.map(\.resource)
      + (contractMetrics?.metrics.map(\.resource) ?? [])
    for resource in resources {
      if let decoded = decodeContractResourceAttributes(
        resource.attributes,
        expectedFieldKeys: definition.schema.fieldKeys
      ) {
        return DecodedContractResource(
          contractVersion: decoded.version,
          fields: decoded.fields
        )
      }
    }
    return nil
  }
}

package func decodedContractLogSeverity(_ severity: Severity?) -> TelemetryLogSeverity? {
  switch severity {
  case .info: .info
  case .error: .error
  default: nil
  }
}

package func decodeContractResourceAttributes(
  _ attributes: [String: AttributeValue],
  expectedFieldKeys: Set<String>
) -> (version: Int, fields: [String: TelemetryDecodedScalar])? {
  let expectedKeys = expectedFieldKeys.union([TelemetryContractCatalog.contractVersionKey])
  guard Set(attributes.keys) == expectedKeys else { return nil }
  return decodeRecord(attributes)
}

private func decodeRecord(
  _ attributes: [String: AttributeValue]
) -> (version: Int, fields: [String: TelemetryDecodedScalar])? {
  guard case .int(let version) = attributes[TelemetryContractCatalog.contractVersionKey] else {
    return nil
  }
  var fields: [String: TelemetryDecodedScalar] = [:]
  for (key, value) in attributes where key != TelemetryContractCatalog.contractVersionKey {
    guard let value = decodeScalar(value) else { return nil }
    fields[key] = value
  }
  return (version, fields)
}

private func decodeScalar(_ value: AttributeValue) -> TelemetryDecodedScalar? {
  switch value {
  case .string(let value):
    .string(value)
  case .int(let value):
    .integer(value)
  case .double(let value):
    .double(value)
  case .bool(let value):
    .boolean(value)
  default:
    nil
  }
}
