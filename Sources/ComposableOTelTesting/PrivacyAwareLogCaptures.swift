import ComposableOTel
import OpenTelemetryApi

/// The approved public-value domain captured from a privacy-aware log.
public enum CapturedTelemetryLogValueKind: String, Equatable, Sendable {
  case featureID = "feature-id"
  case actionID = "action-id"
  case effectID = "effect-id"
  case dependencyID = "dependency-id"
  case operationID = "operation-id"
  case routeID = "route-id"
  case errorTypeID = "error-type-id"
  case errorCategoryID = "error-category-id"
  case errorCodeID = "error-code-id"
  case serviceID = "service-id"
  case serviceVersionID = "service-version-id"
  case outcome
  case navigationOperation = "navigation-operation"
  case boolean
  case integer
  case durationMilliseconds = "duration-ms"
  case countBucket = "count-bucket"
  case correlationID = "correlation-id"
}

/// One typed public interpolation captured from a privacy-aware log.
public struct CapturedTelemetryLogPublicValue: Equatable, Sendable {
  public let index: Int
  public let kind: CapturedTelemetryLogValueKind
  public let value: TelemetryDecodedScalar

  public init(
    index: Int,
    kind: CapturedTelemetryLogValueKind,
    value: TelemetryDecodedScalar
  ) {
    self.index = index
    self.kind = kind
    self.value = value
  }
}

/// A decoded privacy-aware log after the package privacy boundary.
public struct CapturedTelemetryLog: Equatable, Sendable {
  public let eventName: String
  public let template: String
  public let templateID: String
  public let body: String
  public let severity: TelemetryLogSeverity
  public let publicValues: [CapturedTelemetryLogPublicValue]
  public let spanContext: SpanContext?

  public init(
    eventName: String,
    template: String,
    templateID: String,
    body: String,
    severity: TelemetryLogSeverity,
    publicValues: [CapturedTelemetryLogPublicValue],
    spanContext: SpanContext?
  ) {
    self.eventName = eventName
    self.template = template
    self.templateID = templateID
    self.body = body
    self.severity = severity
    self.publicValues = publicValues
    self.spanContext = spanContext
  }
}

extension InMemoryLogCollector {
  /// Privacy-aware interpolated logs in recording order.
  public var privacyAwareLogs: [CapturedTelemetryLog] {
    allRecords.compactMap { record in
      guard
        record.eventName == TelemetryLogWireFormat.eventName,
        case .string(let template) = record.attributes[TelemetryLogWireFormat.templateKey],
        case .string(let templateID) = record.attributes[TelemetryLogWireFormat.templateIDKey],
        case .int(let publicCount) = record.attributes[TelemetryLogWireFormat.publicValueCountKey],
        case .string(let body) = record.body,
        let severity = decodedContractLogSeverity(record.severity)
      else {
        return nil
      }
      var publicValues: [CapturedTelemetryLogPublicValue] = []
      publicValues.reserveCapacity(publicCount)
      for index in 0..<publicCount {
        guard
          case .string(let rawKind) = record.attributes[
            TelemetryLogWireFormat.publicTypeKey(index)
          ],
          let kind = CapturedTelemetryLogValueKind(rawValue: rawKind),
          let rawValue = record.attributes[TelemetryLogWireFormat.publicValueKey(index)],
          let value = capturedScalar(rawValue)
        else {
          return nil
        }
        publicValues.append(.init(index: index, kind: kind, value: value))
      }
      return CapturedTelemetryLog(
        eventName: record.eventName ?? TelemetryLogWireFormat.eventName,
        template: template,
        templateID: templateID,
        body: body,
        severity: severity,
        publicValues: publicValues,
        spanContext: record.spanContext
      )
    }
  }
}

private func capturedScalar(_ value: AttributeValue) -> TelemetryDecodedScalar? {
  switch value {
  case .string(let value): .string(value)
  case .int(let value): .integer(value)
  case .double(let value): .double(value)
  case .bool(let value): .boolean(value)
  default: nil
  }
}
