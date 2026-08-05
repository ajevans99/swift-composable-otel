import Foundation
import OpenTelemetryApi

/// Privacy annotation for approved interpolated log values.
public enum TelemetryLogPrivacy: Sendable {
  case `private`
  case `public`
}

/// A clamped integer that may be explicitly exported from an interpolated log.
public struct TelemetryLogInteger: Equatable, Sendable {
  public static let minimum = Int64(-1_000_000)
  public static let maximum = Int64(1_000_000)

  public let rawValue: Int64

  public init(_ value: Int64) {
    rawValue = min(Self.maximum, max(Self.minimum, value))
  }
}

/// A clamped millisecond duration that may be explicitly exported from an interpolated log.
public struct TelemetryLogDuration: Equatable, Sendable {
  public static let maximumMilliseconds = Int64(86_400_000)

  public let milliseconds: Int64

  public init(milliseconds: Int64) {
    self.milliseconds = min(Self.maximumMilliseconds, max(0, milliseconds))
  }
}

/// A finite count bucket that may be explicitly exported from an interpolated log.
public enum TelemetryLogCountBucket: String, CaseIterable, Sendable {
  case zero
  case one
  case twoToFive = "two-to-five"
  case sixToTwenty = "six-to-twenty"
  case twentyOneToHundred = "twenty-one-to-hundred"
  case overHundred = "over-hundred"

  public init(count: Int) {
    switch count {
    case ...0: self = .zero
    case 1: self = .one
    case 2...5: self = .twoToFive
    case 6...20: self = .sixToTwenty
    case 21...100: self = .twentyOneToHundred
    default: self = .overHundred
    }
  }
}

/// An explicit fixed-width correlation identifier approved for public log interpolation.
public struct TelemetryCorrelationID: Equatable, Hashable, Sendable {
  public let rawValue: UUID

  public init(_ rawValue: UUID) {
    self.rawValue = rawValue
  }
}

/// A privacy-aware interpolated log message.
///
/// Unannotated interpolations are private and are replaced with ``redactionToken`` while the message
/// is being built. Explicit public interpolation is available only through overloads for
/// package-approved bounded values.
public struct TelemetryLogMessage:
  ExpressibleByStringLiteral, ExpressibleByStringInterpolation, Sendable
{
  public typealias StringLiteralType = StaticString

  public static let maximumTemplateUTF8Bytes = 512
  public static let maximumBodyUTF8Bytes = 1_024
  public static let maximumInterpolationCount = 16
  public static let maximumPublicValueCount = 8
  public static let redactionToken = "<private>"

  public let template: String
  public let templateID: String
  public let isValid: Bool

  package let interpolationCount: Int
  package let publicValues: [TelemetryLogApprovedPublicValue]

  public init(stringLiteral value: StaticString) {
    var interpolation = StringInterpolation(
      literalCapacity: value.utf8CodeUnitCount,
      interpolationCount: 0
    )
    interpolation.appendLiteral(value)
    self.init(stringInterpolation: interpolation)
  }

  public init(stringInterpolation: StringInterpolation) {
    template = stringInterpolation.template
    templateID = TelemetryLogWireFormat.templateID(for: stringInterpolation.template)
    interpolationCount = stringInterpolation.interpolationCount
    publicValues = stringInterpolation.publicValues
    isValid =
      stringInterpolation.isValid
      && stringInterpolation.template.utf8.count <= Self.maximumTemplateUTF8Bytes
      && stringInterpolation.interpolationCount <= Self.maximumInterpolationCount
      && stringInterpolation.publicValues.count <= Self.maximumPublicValueCount
  }

  public struct StringInterpolation: StringInterpolationProtocol {
    public typealias StringLiteralType = StaticString

    fileprivate var template: String
    fileprivate var interpolationCount: Int
    fileprivate var publicValues: [TelemetryLogApprovedPublicValue]
    fileprivate var isValid: Bool

    public init(literalCapacity: Int, interpolationCount: Int) {
      template = ""
      template.reserveCapacity(literalCapacity + interpolationCount * 12)
      self.interpolationCount = 0
      publicValues = []
      isValid = interpolationCount <= TelemetryLogMessage.maximumInterpolationCount
    }

    public mutating func appendLiteral(_ literal: StaticString) {
      #if DEBUG
        TelemetryDebugRenderingContext.buffer?.append(String(describing: literal))
      #endif
      template += TelemetryLogWireFormat.escapeLiteral(String(describing: literal))
      validateBounds()
    }

    /// Appends a private value without evaluating or retaining it.
    public mutating func appendInterpolation<Value>(_ value: @autoclosure () -> Value) {
      #if DEBUG
        if let buffer = TelemetryDebugRenderingContext.buffer {
          buffer.append(String(describing: value()))
        }
      #endif
      appendPrivate()
    }

    public mutating func appendInterpolation(
      _ value: Bool,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .boolean(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: TelemetryLogInteger,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .integer(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: TelemetryLogDuration,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .duration(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: TelemetryLogCountBucket,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .countBucket(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: TelemetryCorrelationID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .correlationID(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: FeatureID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .feature(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: ActionID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .action(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: EffectID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .effect(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: DependencyID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .dependency(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: OperationID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .operation(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: RouteID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .route(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: ErrorTypeID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .errorType(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: ErrorCategoryID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .errorCategory(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: ErrorCodeID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .errorCode(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: ServiceID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .service(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: ServiceVersionID,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .serviceVersion(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: TelemetryOutcome,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .outcome(value) }, privacy: privacy)
    }

    public mutating func appendInterpolation(
      _ value: NavigationOperation,
      privacy: TelemetryLogPrivacy
    ) {
      append(value: { .navigationOperation(value) }, privacy: privacy)
    }

    private mutating func append(
      value: () -> TelemetryLogApprovedPublicValue,
      privacy: TelemetryLogPrivacy
    ) {
      switch privacy {
      case .private:
        #if DEBUG
          if let buffer = TelemetryDebugRenderingContext.buffer {
            buffer.append(value().debugRendered)
          }
        #endif
        appendPrivate()
      case .public:
        let value = value()
        interpolationCount += 1
        let index = publicValues.count
        publicValues.append(value)
        template += TelemetryLogWireFormat.publicMarker(index: index, kind: value.kind)
        #if DEBUG
          TelemetryDebugRenderingContext.buffer?.append(value.debugRendered)
        #endif
        validateBounds()
      }
    }

    private mutating func appendPrivate() {
      interpolationCount += 1
      template += TelemetryLogWireFormat.privateMarker
      validateBounds()
    }

    private mutating func validateBounds() {
      if template.utf8.count > TelemetryLogMessage.maximumTemplateUTF8Bytes
        || interpolationCount > TelemetryLogMessage.maximumInterpolationCount
        || publicValues.count > TelemetryLogMessage.maximumPublicValueCount
      {
        isValid = false
      }
    }
  }
}

/// The synchronous outcome of recording a privacy-aware interpolated log.
public enum TelemetryLogRecordingResult: Equatable, Sendable {
  case recorded
  case disabled
  case dropped
  case invalidMessage
}

package enum TelemetryLogPublicValueKind: String, Sendable {
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

package enum TelemetryLogApprovedPublicValue: Sendable {
  case feature(FeatureID)
  case action(ActionID)
  case effect(EffectID)
  case dependency(DependencyID)
  case operation(OperationID)
  case route(RouteID)
  case errorType(ErrorTypeID)
  case errorCategory(ErrorCategoryID)
  case errorCode(ErrorCodeID)
  case service(ServiceID)
  case serviceVersion(ServiceVersionID)
  case outcome(TelemetryOutcome)
  case navigationOperation(NavigationOperation)
  case boolean(Bool)
  case integer(TelemetryLogInteger)
  case duration(TelemetryLogDuration)
  case countBucket(TelemetryLogCountBucket)
  case correlationID(TelemetryCorrelationID)

  var kind: TelemetryLogPublicValueKind {
    switch self {
    case .feature: .featureID
    case .action: .actionID
    case .effect: .effectID
    case .dependency: .dependencyID
    case .operation: .operationID
    case .route: .routeID
    case .errorType: .errorTypeID
    case .errorCategory: .errorCategoryID
    case .errorCode: .errorCodeID
    case .service: .serviceID
    case .serviceVersion: .serviceVersionID
    case .outcome: .outcome
    case .navigationOperation: .navigationOperation
    case .boolean: .boolean
    case .integer: .integer
    case .duration: .durationMilliseconds
    case .countBucket: .countBucket
    case .correlationID: .correlationID
    }
  }

  #if DEBUG
    var debugRendered: String {
      switch self {
      case .feature(let value): value.rawValue
      case .action(let value): value.rawValue
      case .effect(let value): value.rawValue
      case .dependency(let value): value.rawValue
      case .operation(let value): value.rawValue
      case .route(let value): value.rawValue
      case .errorType(let value): value.rawValue
      case .errorCategory(let value): value.rawValue
      case .errorCode(let value): value.rawValue
      case .service(let value): value.rawValue
      case .serviceVersion(let value): value.rawValue
      case .outcome(let value): value.rawValue
      case .navigationOperation(let value): value.rawValue
      case .boolean(let value): String(value)
      case .integer(let value): String(value.rawValue)
      case .duration(let value): String(value.milliseconds)
      case .countBucket(let value): value.rawValue
      case .correlationID(let value): value.rawValue.uuidString.lowercased()
      }
    }
  #endif

  func sanitized(using policy: TelemetryPolicy) -> TelemetryLogSanitizedPublicValue {
    switch self {
    case .feature(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .action(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .effect(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .dependency(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .operation(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .route(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .errorType(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .errorCategory(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .errorCode(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .service(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .serviceVersion(let value):
      .string(kind, policy.schema.bounded(value).rawValue)
    case .outcome(let value):
      .string(kind, value.rawValue)
    case .navigationOperation(let value):
      .string(kind, value.rawValue)
    case .boolean(let value):
      .boolean(value)
    case .integer(let value):
      .integer(kind, value.rawValue)
    case .duration(let value):
      .integer(kind, value.milliseconds)
    case .countBucket(let value):
      .string(kind, value.rawValue)
    case .correlationID(let value):
      .string(kind, value.rawValue.uuidString.lowercased())
    }
  }
}

package enum TelemetryLogSanitizedPublicValue: Sendable {
  case string(TelemetryLogPublicValueKind, String)
  case integer(TelemetryLogPublicValueKind, Int64)
  case boolean(Bool)

  var kind: TelemetryLogPublicValueKind {
    switch self {
    case .string(let kind, _), .integer(let kind, _): kind
    case .boolean: .boolean
    }
  }

  var attributeValue: AttributeValue? {
    switch self {
    case .string(_, let value): .string(value)
    case .integer(_, let value): Int(exactly: value).map(AttributeValue.int)
    case .boolean(let value): .bool(value)
    }
  }

  var rendered: String {
    switch self {
    case .string(_, let value): value
    case .integer(_, let value): String(value)
    case .boolean(let value): String(value)
    }
  }
}

package enum TelemetryLogWireFormat {
  package static let eventName = ComposableOTelSemantics.Events.applicationLog
  static let privateMarker = "<private>"
  package static let templateKey = "log.template"
  package static let templateIDKey = "log.template_id"
  package static let interpolationCountKey = "log.interpolation_count"
  package static let publicValueCountKey = "log.public_count"

  package static func publicTypeKey(_ index: Int) -> String {
    "log.public.\(index).type"
  }

  package static func publicValueKey(_ index: Int) -> String {
    "log.public.\(index).value"
  }

  static func publicMarker(index: Int, kind: TelemetryLogPublicValueKind) -> String {
    "<public:\(index):\(kind.rawValue)>"
  }

  static func escapeLiteral(_ literal: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(literal.count)
    for character in literal {
      if character == "\\" || character == "<" {
        escaped.append("\\")
      }
      escaped.append(character)
    }
    return escaped
  }

  package static func templateID(for template: String) -> String {
    var hash = UInt64(14_695_981_039_346_656_037)
    for byte in template.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
  }

  static func makeRecord(
    from message: TelemetryLogMessage,
    severity: TelemetryLogSeverity,
    policy: TelemetryPolicy
  ) -> TelemetryPrivacyAwareLogRecord? {
    guard message.isValid else { return nil }
    let values = message.publicValues.map { $0.sanitized(using: policy) }
    guard
      let body = render(
        template: message.template,
        interpolationCount: message.interpolationCount,
        publicValues: values
      ),
      body.utf8.count <= TelemetryLogMessage.maximumBodyUTF8Bytes
    else {
      return nil
    }
    var attributes: [String: AttributeValue] = [
      templateKey: .string(message.template),
      templateIDKey: .string(message.templateID),
      interpolationCountKey: .int(message.interpolationCount),
      publicValueCountKey: .int(values.count),
    ]
    for (index, value) in values.enumerated() {
      guard let attributeValue = value.attributeValue else { return nil }
      attributes[publicTypeKey(index)] = .string(value.kind.rawValue)
      attributes[publicValueKey(index)] = attributeValue
    }
    return TelemetryPrivacyAwareLogRecord(
      severity: severity,
      body: body,
      attributes: attributes
    )
  }

  package static func sanitize(
    body _: AttributeValue?,
    attributes: [String: AttributeValue],
    policy: TelemetryPolicy
  ) -> (body: AttributeValue, attributes: [String: AttributeValue])? {
    guard
      case .string(let template) = attributes[templateKey],
      template.utf8.count <= TelemetryLogMessage.maximumTemplateUTF8Bytes,
      case .string(let identity) = attributes[templateIDKey],
      identity == templateID(for: template),
      case .int(let interpolationCount) = attributes[interpolationCountKey],
      (0...TelemetryLogMessage.maximumInterpolationCount).contains(interpolationCount),
      case .int(let publicValueCount) = attributes[publicValueCountKey],
      (0...TelemetryLogMessage.maximumPublicValueCount).contains(publicValueCount)
    else {
      return nil
    }
    let expectedKeys =
      Set([templateKey, templateIDKey, interpolationCountKey, publicValueCountKey])
      .union((0..<publicValueCount).flatMap { [publicTypeKey($0), publicValueKey($0)] })
    guard Set(attributes.keys) == expectedKeys else { return nil }

    var sanitizedValues: [TelemetryLogSanitizedPublicValue] = []
    sanitizedValues.reserveCapacity(publicValueCount)
    for index in 0..<publicValueCount {
      guard
        case .string(let rawKind) = attributes[publicTypeKey(index)],
        let kind = TelemetryLogPublicValueKind(rawValue: rawKind),
        let rawValue = attributes[publicValueKey(index)],
        let value = sanitize(rawValue, kind: kind, policy: policy)
      else {
        return nil
      }
      sanitizedValues.append(value)
    }
    guard
      let body = render(
        template: template,
        interpolationCount: interpolationCount,
        publicValues: sanitizedValues
      ),
      body.utf8.count <= TelemetryLogMessage.maximumBodyUTF8Bytes
    else {
      return nil
    }

    var sanitizedAttributes: [String: AttributeValue] = [
      templateKey: .string(template),
      templateIDKey: .string(identity),
      interpolationCountKey: .int(interpolationCount),
      publicValueCountKey: .int(publicValueCount),
    ]
    for (index, value) in sanitizedValues.enumerated() {
      guard let attributeValue = value.attributeValue else { return nil }
      sanitizedAttributes[publicTypeKey(index)] = .string(value.kind.rawValue)
      sanitizedAttributes[publicValueKey(index)] = attributeValue
    }
    return (.string(body), sanitizedAttributes)
  }

  private static func sanitize(
    _ value: AttributeValue,
    kind: TelemetryLogPublicValueKind,
    policy: TelemetryPolicy
  ) -> TelemetryLogSanitizedPublicValue? {
    switch kind {
    case .featureID:
      return boundedIdentifier(value, as: FeatureID.self, kind: kind, policy.schema.bounded)
    case .actionID:
      return boundedIdentifier(value, as: ActionID.self, kind: kind, policy.schema.bounded)
    case .effectID:
      return boundedIdentifier(value, as: EffectID.self, kind: kind, policy.schema.bounded)
    case .dependencyID:
      return boundedIdentifier(value, as: DependencyID.self, kind: kind, policy.schema.bounded)
    case .operationID:
      return boundedIdentifier(value, as: OperationID.self, kind: kind, policy.schema.bounded)
    case .routeID:
      return boundedIdentifier(value, as: RouteID.self, kind: kind, policy.schema.bounded)
    case .errorTypeID:
      return boundedIdentifier(value, as: ErrorTypeID.self, kind: kind, policy.schema.bounded)
    case .errorCategoryID:
      return boundedIdentifier(value, as: ErrorCategoryID.self, kind: kind, policy.schema.bounded)
    case .errorCodeID:
      return boundedIdentifier(value, as: ErrorCodeID.self, kind: kind, policy.schema.bounded)
    case .serviceID:
      return boundedIdentifier(value, as: ServiceID.self, kind: kind, policy.schema.bounded)
    case .serviceVersionID:
      return boundedIdentifier(value, as: ServiceVersionID.self, kind: kind, policy.schema.bounded)
    case .outcome:
      guard case .string(let rawValue) = value, TelemetryOutcome(rawValue: rawValue) != nil else {
        return nil
      }
      return .string(kind, rawValue)
    case .navigationOperation:
      guard
        case .string(let rawValue) = value,
        NavigationOperation(rawValue: rawValue) != nil
      else {
        return nil
      }
      return .string(kind, rawValue)
    case .boolean:
      guard case .bool(let value) = value else { return nil }
      return .boolean(value)
    case .integer:
      guard
        case .int(let value) = value,
        (Int(TelemetryLogInteger.minimum)...Int(TelemetryLogInteger.maximum)).contains(value)
      else {
        return nil
      }
      return .integer(kind, Int64(value))
    case .durationMilliseconds:
      guard
        case .int(let value) = value,
        (0...Int(TelemetryLogDuration.maximumMilliseconds)).contains(value)
      else {
        return nil
      }
      return .integer(kind, Int64(value))
    case .countBucket:
      guard
        case .string(let rawValue) = value,
        TelemetryLogCountBucket(rawValue: rawValue) != nil
      else {
        return nil
      }
      return .string(kind, rawValue)
    case .correlationID:
      guard
        case .string(let rawValue) = value,
        let uuid = UUID(uuidString: rawValue),
        uuid.uuidString.lowercased() == rawValue
      else {
        return nil
      }
      return .string(kind, rawValue)
    }
  }

  private static func boundedIdentifier<Kind: TelemetryIdentifierKind>(
    _ value: AttributeValue,
    as _: TelemetryIdentifier<Kind>.Type,
    kind: TelemetryLogPublicValueKind,
    _ bound: (TelemetryIdentifier<Kind>) -> TelemetryIdentifier<Kind>
  ) -> TelemetryLogSanitizedPublicValue? {
    guard
      case .string(let rawValue) = value,
      let identifier = TelemetryIdentifier<Kind>(validating: rawValue)
    else {
      return .string(kind, TelemetryIdentifier<Kind>.other.rawValue)
    }
    return .string(kind, bound(identifier).rawValue)
  }

  private static func render(
    template: String,
    interpolationCount: Int,
    publicValues: [TelemetryLogSanitizedPublicValue]
  ) -> String? {
    var body = ""
    body.reserveCapacity(template.count)
    var index = template.startIndex
    var seenInterpolations = 0
    var seenPublicValues = 0

    while index < template.endIndex {
      let character = template[index]
      if character == "\\" {
        let escapedIndex = template.index(after: index)
        guard escapedIndex < template.endIndex else { return nil }
        let escaped = template[escapedIndex]
        guard escaped == "\\" || escaped == "<" else { return nil }
        body.append(escaped)
        index = template.index(after: escapedIndex)
      } else if template[index...].hasPrefix(privateMarker) {
        body += TelemetryLogMessage.redactionToken
        seenInterpolations += 1
        index = template.index(index, offsetBy: privateMarker.count)
      } else if character == "<" {
        guard let closing = template[index...].firstIndex(of: ">") else { return nil }
        let marker = String(template[index...closing])
        guard seenPublicValues < publicValues.count else { return nil }
        let value = publicValues[seenPublicValues]
        guard marker == publicMarker(index: seenPublicValues, kind: value.kind) else {
          return nil
        }
        body += value.rendered
        seenPublicValues += 1
        seenInterpolations += 1
        index = template.index(after: closing)
      } else {
        body.append(character)
        index = template.index(after: index)
      }
    }
    guard
      seenInterpolations == interpolationCount,
      seenPublicValues == publicValues.count
    else {
      return nil
    }
    return body
  }
}

package struct TelemetryPrivacyAwareLogRecord: Sendable {
  package let severity: TelemetryLogSeverity
  package let body: String
  package let attributes: [String: AttributeValue]
}

package struct TelemetryPrivacyAwareLogRecorder: Sendable {
  private let operation: @Sendable (TelemetryPrivacyAwareLogRecord) -> TelemetryLogRecordingResult

  package init(
    _ operation:
      @escaping @Sendable (TelemetryPrivacyAwareLogRecord) -> TelemetryLogRecordingResult
  ) {
    self.operation = operation
  }

  package func record(_ record: TelemetryPrivacyAwareLogRecord) -> TelemetryLogRecordingResult {
    operation(record)
  }

  static func logger(_ logger: SendableLogger) -> Self {
    Self { record in
      logger.logRecordBuilder()
        .setSeverity(record.severity.otelSeverity)
        .setBody(.string(record.body))
        .setAttributes(record.attributes)
        .setEventName(TelemetryLogWireFormat.eventName)
        .emit()
      return .recorded
    }
  }
}
