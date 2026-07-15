import Foundation
import OpenTelemetryApi

public enum TelemetryContractError: Error, Equatable, Sendable {
  case invalidName
  case invalidFieldKey
  case invalidValue
  case invalidVersion
  case invalidDefinition
  case duplicateDefinition
  case invalidPayload(field: TelemetryFieldKey?)
  case unregisteredDefinition
  case resourceDefinitionMismatch
}

public struct TelemetryContractName: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard Self.isValid(rawValue) else { throw TelemetryContractError.invalidName }
    self.rawValue = rawValue
  }

  private static func isValid(_ value: String) -> Bool {
    guard (1...63).contains(value.utf8.count), let first = value.utf8.first else { return false }
    guard (97...122).contains(first) else { return false }
    return value.utf8.allSatisfy {
      (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
    }
  }
}

public struct TelemetryFieldKey: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard Self.isValid(rawValue) else { throw TelemetryContractError.invalidFieldKey }
    self.rawValue = rawValue
  }

  private static func isValid(_ value: String) -> Bool {
    guard (1...63).contains(value.utf8.count), let first = value.utf8.first else { return false }
    guard (97...122).contains(first) else { return false }
    return value.utf8.allSatisfy {
      (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
    }
  }
}

public struct TelemetryStringValue: Hashable, Sendable {
  public static let maximumLength = 64

  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard Self.isValid(rawValue) else { throw TelemetryContractError.invalidValue }
    self.rawValue = rawValue
  }

  private static func isValid(_ value: String) -> Bool {
    guard (1...maximumLength).contains(value.utf8.count), let first = value.utf8.first else {
      return false
    }
    guard
      (65...90).contains(first) || (97...122).contains(first) || (48...57).contains(first)
        || first == 123
    else {
      return false
    }
    return value.utf8.allSatisfy {
      (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        || $0 == 43 || $0 == 45 || $0 == 46 || $0 == 95 || $0 == 123 || $0 == 125
    }
  }
}

public struct TelemetryEnumValue: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) throws {
    guard (1...48).contains(rawValue.utf8.count), let first = rawValue.utf8.first else {
      throw TelemetryContractError.invalidValue
    }
    guard (97...122).contains(first) else { throw TelemetryContractError.invalidValue }
    guard
      rawValue.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
      })
    else {
      throw TelemetryContractError.invalidValue
    }
    self.rawValue = rawValue
  }
}

public enum TelemetryScalarValue: Equatable, Sendable {
  case string(TelemetryStringValue)
  case enumeration(TelemetryEnumValue)
  case integer(Int64)
  case double(Double)
  case boolean(Bool)

  package var attributeValue: AttributeValue? {
    switch self {
    case .string(let value):
      .string(value.rawValue)
    case .enumeration(let value):
      .string(value.rawValue)
    case .integer(let value):
      Int(exactly: value).map(AttributeValue.int)
    case .double(let value):
      .double(value)
    case .boolean(let value):
      .bool(value)
    }
  }
}

public struct TelemetryContractVersion: Equatable, Hashable, Sendable {
  public let rawValue: Int

  public init(_ rawValue: Int) throws {
    guard (1...Int(Int32.max)).contains(rawValue) else {
      throw TelemetryContractError.invalidVersion
    }
    self.rawValue = rawValue
  }
}

public enum TelemetryFieldPresence: String, Sendable {
  case required
  case optional
}

public struct TelemetryField<Payload: Sendable>: @unchecked Sendable {
  public let key: TelemetryFieldKey
  public let presence: TelemetryFieldPresence

  package let fingerprint: String
  package var isRequired: Bool { presence == .required }
  package let maximumCardinality: Int?
  private let extractValue: @Sendable (Payload) -> TelemetryScalarValue?
  private let validateValue: @Sendable (TelemetryScalarValue) -> Bool
  private let validateAttribute: @Sendable (AttributeValue) -> Bool
  private let decodeAttribute: @Sendable (AttributeValue) -> TelemetryScalarValue?

  private init(
    key: TelemetryFieldKey,
    presence: TelemetryFieldPresence,
    fingerprint: String,
    maximumCardinality: Int?,
    extract: @escaping @Sendable (Payload) -> TelemetryScalarValue?,
    validate: @escaping @Sendable (TelemetryScalarValue) -> Bool,
    validateAttribute: @escaping @Sendable (AttributeValue) -> Bool,
    decodeAttribute: @escaping @Sendable (AttributeValue) -> TelemetryScalarValue?
  ) {
    self.key = key
    self.presence = presence
    self.fingerprint = "\(key.rawValue):\(presence.rawValue):\(fingerprint)"
    self.maximumCardinality = maximumCardinality.map {
      presence == .optional ? $0 + 1 : $0
    }
    extractValue = extract
    validateValue = validate
    self.validateAttribute = validateAttribute
    self.decodeAttribute = decodeAttribute
  }

  public static func string(
    _ key: TelemetryFieldKey,
    presence: TelemetryFieldPresence = .required,
    maximumLength: Int = TelemetryStringValue.maximumLength,
    _ extract: @escaping @Sendable (Payload) -> TelemetryStringValue?
  ) throws -> Self {
    guard (1...TelemetryStringValue.maximumLength).contains(maximumLength) else {
      throw TelemetryContractError.invalidDefinition
    }
    return Self(
      key: key,
      presence: presence,
      fingerprint: "string:\(maximumLength)",
      maximumCardinality: nil,
      extract: { extract($0).map(TelemetryScalarValue.string) },
      validate: {
        guard case .string(let value) = $0 else { return false }
        return value.rawValue.utf8.count <= maximumLength
      },
      validateAttribute: {
        guard case .string(let value) = $0 else { return false }
        return (try? TelemetryStringValue(value)) != nil
          && value.utf8.count <= maximumLength
      },
      decodeAttribute: {
        guard case .string(let value) = $0,
          value.utf8.count <= maximumLength,
          let value = try? TelemetryStringValue(value)
        else { return nil }
        return .string(value)
      }
    )
  }

  public static func enumeration(
    _ key: TelemetryFieldKey,
    allowedValues: Set<TelemetryEnumValue>,
    presence: TelemetryFieldPresence = .required,
    _ extract: @escaping @Sendable (Payload) -> TelemetryEnumValue?
  ) throws -> Self {
    guard !allowedValues.isEmpty, allowedValues.count <= 64 else {
      throw TelemetryContractError.invalidDefinition
    }
    let allowed = allowedValues.map(\.rawValue).sorted().joined(separator: ",")
    return Self(
      key: key,
      presence: presence,
      fingerprint: "enum:\(allowed)",
      maximumCardinality: allowedValues.count,
      extract: { extract($0).map(TelemetryScalarValue.enumeration) },
      validate: {
        guard case .enumeration(let value) = $0 else { return false }
        return allowedValues.contains(value)
      },
      validateAttribute: {
        guard case .string(let value) = $0, let value = try? TelemetryEnumValue(value) else {
          return false
        }
        return allowedValues.contains(value)
      },
      decodeAttribute: {
        guard case .string(let rawValue) = $0,
          let value = try? TelemetryEnumValue(rawValue),
          allowedValues.contains(value)
        else { return nil }
        return .enumeration(value)
      }
    )
  }

  public static func integer(
    _ key: TelemetryFieldKey,
    range: ClosedRange<Int64>,
    presence: TelemetryFieldPresence = .required,
    _ extract: @escaping @Sendable (Payload) -> Int64?
  ) throws -> Self {
    guard
      range.lowerBound >= Int64(Int32.min),
      range.upperBound <= Int64(Int32.max),
      range.lowerBound <= range.upperBound
    else {
      throw TelemetryContractError.invalidDefinition
    }
    return Self(
      key: key,
      presence: presence,
      fingerprint: "int:\(range.lowerBound):\(range.upperBound)",
      maximumCardinality: {
        let width = range.upperBound.subtractingReportingOverflow(range.lowerBound)
        guard !width.overflow, width.partialValue < 1_024 else { return nil }
        return Int(width.partialValue + 1)
      }(),
      extract: { extract($0).map(TelemetryScalarValue.integer) },
      validate: {
        guard case .integer(let value) = $0 else { return false }
        return range.contains(value)
      },
      validateAttribute: {
        guard case .int(let value) = $0 else { return false }
        return range.contains(Int64(value))
      },
      decodeAttribute: {
        guard case .int(let value) = $0, range.contains(Int64(value)) else { return nil }
        return .integer(Int64(value))
      }
    )
  }

  public static func double(
    _ key: TelemetryFieldKey,
    range: ClosedRange<Double>,
    presence: TelemetryFieldPresence = .required,
    _ extract: @escaping @Sendable (Payload) -> Double?
  ) throws -> Self {
    guard
      range.lowerBound.isFinite,
      range.upperBound.isFinite,
      range.lowerBound <= range.upperBound
    else {
      throw TelemetryContractError.invalidDefinition
    }
    return Self(
      key: key,
      presence: presence,
      fingerprint: "double:\(range.lowerBound):\(range.upperBound)",
      maximumCardinality: nil,
      extract: { extract($0).map(TelemetryScalarValue.double) },
      validate: {
        guard case .double(let value) = $0 else { return false }
        return value.isFinite && range.contains(value)
      },
      validateAttribute: {
        guard case .double(let value) = $0 else { return false }
        return value.isFinite && range.contains(value)
      },
      decodeAttribute: {
        guard case .double(let value) = $0, value.isFinite, range.contains(value) else {
          return nil
        }
        return .double(value)
      }
    )
  }

  public static func boolean(
    _ key: TelemetryFieldKey,
    presence: TelemetryFieldPresence = .required,
    _ extract: @escaping @Sendable (Payload) -> Bool?
  ) -> Self {
    Self(
      key: key,
      presence: presence,
      fingerprint: "bool",
      maximumCardinality: 2,
      extract: { extract($0).map(TelemetryScalarValue.boolean) },
      validate: {
        guard case .boolean = $0 else { return false }
        return true
      },
      validateAttribute: {
        guard case .bool = $0 else { return false }
        return true
      },
      decodeAttribute: {
        guard case .bool(let value) = $0 else { return nil }
        return .boolean(value)
      }
    )
  }

  package func extract(from payload: Payload) throws -> (String, AttributeValue)? {
    guard let value = extractValue(payload) else {
      if presence == .required {
        throw TelemetryContractError.invalidPayload(field: key)
      }
      return nil
    }
    guard validateValue(value), let attributeValue = value.attributeValue else {
      throw TelemetryContractError.invalidPayload(field: key)
    }
    return (key.rawValue, attributeValue)
  }

  package func accepts(_ value: AttributeValue) -> Bool {
    validateAttribute(value)
  }

  package func decode(_ value: AttributeValue) -> TelemetryScalarValue? {
    decodeAttribute(value)
  }
}

public enum TelemetryLogSeverity: String, Sendable {
  case info
  case error

  package var otelSeverity: Severity {
    switch self {
    case .info: .info
    case .error: .error
    }
  }
}

public enum TelemetryLogBodyPolicy: Equatable, Sendable {
  case none
  case fixed(TelemetryStringValue)
}

public struct TelemetryCounterDelta: Equatable, Sendable {
  public let rawValue: Int

  public init(_ rawValue: Int) throws {
    guard rawValue > 0 else { throw TelemetryContractError.invalidValue }
    self.rawValue = rawValue
  }
}

package enum TelemetryContractKind: String, Sendable {
  case span
  case log
  case operationalEvent
  case counter
  case resource
}

package struct TelemetryContractIdentity: Hashable, Sendable {
  package let registrationID: UUID
  package let kind: TelemetryContractKind
  package let name: String
  package let fingerprint: String
}

package struct TelemetryContractRecordSchema: Sendable {
  package let identity: TelemetryContractIdentity
  package let fieldKeys: Set<String>
  package let requiredKeys: Set<String>
  package let fieldValidators: [String: @Sendable (AttributeValue) -> Bool]
  package let fieldDecoders: [String: @Sendable (AttributeValue) -> TelemetryScalarValue?]
  package let validateFields: @Sendable ([String: TelemetryScalarValue]) -> Bool
  package let fixedBody: AttributeValue?
  package let bodyIsNil: Bool
  package let severity: TelemetryLogSeverity?
  package let unit: String?
  package let description: String?
  package let maximumSeries: Int?

  package func sanitizedAttributes(
    _ attributes: [String: AttributeValue],
    version: TelemetryContractVersion
  ) -> [String: AttributeValue]? {
    guard attributes[TelemetryContractCatalog.contractVersionKey] == .int(version.rawValue) else {
      return nil
    }
    var fields = attributes
    fields.removeValue(forKey: TelemetryContractCatalog.contractVersionKey)
    guard validatesFields(fields) else { return nil }
    return attributes
  }

  package func validatesFields(_ attributes: [String: AttributeValue]) -> Bool {
    let signalKeys = fieldKeys.subtracting([TelemetryContractCatalog.contractVersionKey])
    let requiredSignalKeys = requiredKeys.subtracting([TelemetryContractCatalog.contractVersionKey])
    guard Set(attributes.keys).isSubset(of: signalKeys),
      requiredSignalKeys.isSubset(of: attributes.keys)
    else {
      return false
    }
    for (key, value) in attributes {
      guard fieldValidators[key]?(value) == true else { return false }
    }
    var decoded: [String: TelemetryScalarValue] = [:]
    for (key, value) in attributes {
      guard let value = fieldDecoders[key]?(value) else { return false }
      decoded[key] = value
    }
    return validateFields(decoded)
  }
}

private func fieldMetadata<Payload: Sendable>(
  _ fields: [TelemetryField<Payload>]
) -> (
  keys: Set<String>,
  required: Set<String>,
  validators: [String: @Sendable (AttributeValue) -> Bool],
  decoders: [String: @Sendable (AttributeValue) -> TelemetryScalarValue?]
) {
  (
    Set(fields.map(\.key.rawValue)).union([TelemetryContractCatalog.contractVersionKey]),
    Set(fields.filter(\.isRequired).map(\.key.rawValue))
      .union([TelemetryContractCatalog.contractVersionKey]),
    Dictionary(
      uniqueKeysWithValues: fields.map { field in
        (field.key.rawValue, { @Sendable value in field.accepts(value) })
      }
    ),
    Dictionary(
      uniqueKeysWithValues: fields.map { field in
        (field.key.rawValue, { @Sendable value in field.decode(value) })
      }
    )
  )
}

private func validateDecodedFields(
  _ fields: [String: TelemetryScalarValue],
  validate: @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool
) -> Bool {
  var typed: [TelemetryFieldKey: TelemetryScalarValue] = [:]
  for (key, value) in fields {
    guard let key = try? TelemetryFieldKey(key) else { return false }
    typed[key] = value
  }
  return validate(typed)
}

private func validatedDefinition<Payload: Sendable>(
  kind: TelemetryContractKind,
  name: TelemetryContractName,
  fields: [TelemetryField<Payload>],
  suffix: String
) throws -> TelemetryContractIdentity {
  let maximumFields = kind == .span ? 15 : 16
  guard fields.count <= maximumFields else { throw TelemetryContractError.invalidDefinition }
  if kind == .resource, fields.contains(where: { !$0.isRequired }) {
    throw TelemetryContractError.invalidDefinition
  }
  let keys = fields.map(\.key)
  guard
    Set(keys).count == keys.count,
    !keys.contains(where: { $0.rawValue == TelemetryContractCatalog.contractVersionKey })
  else {
    throw TelemetryContractError.invalidDefinition
  }
  let fingerprint = (fields.map(\.fingerprint).sorted() + [suffix]).joined(separator: "|")
  return TelemetryContractIdentity(
    registrationID: UUID(),
    kind: kind,
    name: name.rawValue,
    fingerprint: fingerprint
  )
}

private func contractAttributes<Payload: Sendable>(
  fields: [TelemetryField<Payload>],
  payload: Payload,
  validate: @Sendable (Payload) -> Bool,
  version: TelemetryContractVersion
) throws -> [String: AttributeValue] {
  guard validate(payload) else {
    throw TelemetryContractError.invalidPayload(field: nil)
  }
  var attributes: [String: AttributeValue] = [
    TelemetryContractCatalog.contractVersionKey: .int(version.rawValue)
  ]
  for field in fields {
    if let (key, value) = try field.extract(from: payload) {
      attributes[key] = value
    }
  }
  return attributes
}

public struct TelemetrySpanDefinition<Payload: Sendable>: @unchecked Sendable {
  public let name: TelemetryContractName
  private let fields: [TelemetryField<Payload>]
  private let validatePayload: @Sendable (Payload) -> Bool
  private let validateWireFields: @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool
  package let identity: TelemetryContractIdentity

  public init(
    name: TelemetryContractName,
    fields: [TelemetryField<Payload>],
    validate: @escaping @Sendable (Payload) -> Bool = { _ in true },
    validationRule: TelemetryContractName? = nil,
    validateFields: @escaping @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool = {
      _ in true
    }
  ) throws {
    self.name = name
    self.fields = fields
    validatePayload = validate
    validateWireFields = validateFields
    identity = try validatedDefinition(
      kind: .span,
      name: name,
      fields: fields,
      suffix: "span:\(validationRule?.rawValue ?? "none")"
    )
  }

  package func attributes(
    for payload: Payload,
    version: TelemetryContractVersion
  ) throws -> [String: AttributeValue] {
    let attributes = try contractAttributes(
      fields: fields,
      payload: payload,
      validate: validatePayload,
      version: version
    )
    guard schema.sanitizedAttributes(attributes, version: version) != nil else {
      throw TelemetryContractError.invalidPayload(field: nil)
    }
    return attributes
  }

  package var schema: TelemetryContractRecordSchema {
    let metadata = fieldMetadata(fields)
    return TelemetryContractRecordSchema(
      identity: identity,
      fieldKeys: metadata.keys,
      requiredKeys: metadata.required,
      fieldValidators: metadata.validators,
      fieldDecoders: metadata.decoders,
      validateFields: { validateDecodedFields($0, validate: validateWireFields) },
      fixedBody: nil,
      bodyIsNil: true,
      severity: nil,
      unit: nil,
      description: nil,
      maximumSeries: nil
    )
  }
}

public struct TelemetryLogDefinition<Payload: Sendable>: @unchecked Sendable {
  public let eventName: TelemetryContractName
  public let severity: TelemetryLogSeverity
  public let bodyPolicy: TelemetryLogBodyPolicy
  private let fields: [TelemetryField<Payload>]
  private let validatePayload: @Sendable (Payload) -> Bool
  private let validateWireFields: @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool
  package let identity: TelemetryContractIdentity

  public init(
    eventName: TelemetryContractName,
    severity: TelemetryLogSeverity,
    bodyPolicy: TelemetryLogBodyPolicy = .none,
    fields: [TelemetryField<Payload>],
    validate: @escaping @Sendable (Payload) -> Bool = { _ in true },
    validationRule: TelemetryContractName? = nil,
    validateFields: @escaping @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool = {
      _ in true
    }
  ) throws {
    self.eventName = eventName
    self.severity = severity
    self.bodyPolicy = bodyPolicy
    self.fields = fields
    validatePayload = validate
    validateWireFields = validateFields
    let bodyFingerprint: String
    switch bodyPolicy {
    case .none:
      bodyFingerprint = "none"
    case .fixed(let value):
      bodyFingerprint = "fixed:\(value.rawValue)"
    }
    identity = try validatedDefinition(
      kind: .log,
      name: eventName,
      fields: fields,
      suffix:
        "\(severity.rawValue):\(bodyFingerprint):\(validationRule?.rawValue ?? "none")"
    )
  }

  package func attributes(
    for payload: Payload,
    version: TelemetryContractVersion
  ) throws -> [String: AttributeValue] {
    let attributes = try contractAttributes(
      fields: fields,
      payload: payload,
      validate: validatePayload,
      version: version
    )
    guard schema.sanitizedAttributes(attributes, version: version) != nil else {
      throw TelemetryContractError.invalidPayload(field: nil)
    }
    return attributes
  }

  package var body: AttributeValue? {
    switch bodyPolicy {
    case .none: nil
    case .fixed(let value): .string(value.rawValue)
    }
  }

  package var schema: TelemetryContractRecordSchema {
    let metadata = fieldMetadata(fields)
    return TelemetryContractRecordSchema(
      identity: identity,
      fieldKeys: metadata.keys,
      requiredKeys: metadata.required,
      fieldValidators: metadata.validators,
      fieldDecoders: metadata.decoders,
      validateFields: { validateDecodedFields($0, validate: validateWireFields) },
      fixedBody: body,
      bodyIsNil: body == nil,
      severity: severity,
      unit: nil,
      description: nil,
      maximumSeries: nil
    )
  }
}

/// A registered, bodyless operational event with exact typed fields.
///
/// Operational events use the OTLP logs signal internally, but are enabled independently from
/// package-owned TCA logs. Event names and attributes can only come from this registered definition.
public struct TelemetryOperationalEventDefinition<Payload: Sendable>: @unchecked Sendable {
  public let eventName: TelemetryContractName
  private let fields: [TelemetryField<Payload>]
  private let validatePayload: @Sendable (Payload) -> Bool
  private let validateWireFields: @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool
  package let identity: TelemetryContractIdentity

  public init(
    eventName: TelemetryContractName,
    fields: [TelemetryField<Payload>],
    validate: @escaping @Sendable (Payload) -> Bool = { _ in true },
    validationRule: TelemetryContractName? = nil,
    validateFields: @escaping @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool = {
      _ in true
    }
  ) throws {
    self.eventName = eventName
    self.fields = fields
    validatePayload = validate
    validateWireFields = validateFields
    identity = try validatedDefinition(
      kind: .operationalEvent,
      name: eventName,
      fields: fields,
      suffix: "operational-event:\(validationRule?.rawValue ?? "none")"
    )
  }

  package func attributes(
    for payload: Payload,
    version: TelemetryContractVersion
  ) throws -> [String: AttributeValue] {
    let attributes = try contractAttributes(
      fields: fields,
      payload: payload,
      validate: validatePayload,
      version: version
    )
    guard schema.sanitizedAttributes(attributes, version: version) != nil else {
      throw TelemetryContractError.invalidPayload(field: nil)
    }
    return attributes
  }

  package var schema: TelemetryContractRecordSchema {
    let metadata = fieldMetadata(fields)
    return TelemetryContractRecordSchema(
      identity: identity,
      fieldKeys: metadata.keys,
      requiredKeys: metadata.required,
      fieldValidators: metadata.validators,
      fieldDecoders: metadata.decoders,
      validateFields: { validateDecodedFields($0, validate: validateWireFields) },
      fixedBody: nil,
      bodyIsNil: true,
      severity: .info,
      unit: nil,
      description: nil,
      maximumSeries: nil
    )
  }
}

public struct TelemetryCounterDefinition<Payload: Sendable>: @unchecked Sendable {
  public let name: TelemetryContractName
  public let unit: TelemetryStringValue
  public let description: TelemetryStringValue
  public let maximumSeries: Int
  private let fields: [TelemetryField<Payload>]
  private let validatePayload: @Sendable (Payload) -> Bool
  private let validateWireFields: @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool
  package let identity: TelemetryContractIdentity

  public init(
    name: TelemetryContractName,
    unit: TelemetryStringValue,
    description: TelemetryStringValue,
    maximumSeries: Int,
    fields: [TelemetryField<Payload>],
    validate: @escaping @Sendable (Payload) -> Bool = { _ in true },
    validationRule: TelemetryContractName? = nil,
    validateFields: @escaping @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool = {
      _ in true
    }
  ) throws {
    guard (1...1_024).contains(maximumSeries) else {
      throw TelemetryContractError.invalidDefinition
    }
    var computedSeries = 1
    for field in fields {
      guard let cardinality = field.maximumCardinality else {
        throw TelemetryContractError.invalidDefinition
      }
      let multiplied = computedSeries.multipliedReportingOverflow(by: cardinality)
      guard !multiplied.overflow, multiplied.partialValue <= maximumSeries else {
        throw TelemetryContractError.invalidDefinition
      }
      computedSeries = multiplied.partialValue
    }
    self.name = name
    self.unit = unit
    self.description = description
    self.maximumSeries = maximumSeries
    self.fields = fields
    validatePayload = validate
    validateWireFields = validateFields
    identity = try validatedDefinition(
      kind: .counter,
      name: name,
      fields: fields,
      suffix:
        "\(unit.rawValue):\(description.rawValue):\(maximumSeries):"
        + "\(validationRule?.rawValue ?? "none")"
    )
  }

  package func attributes(
    for payload: Payload,
    version: TelemetryContractVersion
  ) throws -> [String: AttributeValue] {
    let attributes = try contractAttributes(
      fields: fields,
      payload: payload,
      validate: validatePayload,
      version: version
    )
    guard schema.sanitizedAttributes(attributes, version: version) != nil else {
      throw TelemetryContractError.invalidPayload(field: nil)
    }
    return attributes
  }

  package var schema: TelemetryContractRecordSchema {
    let metadata = fieldMetadata(fields)
    return TelemetryContractRecordSchema(
      identity: identity,
      fieldKeys: metadata.keys,
      requiredKeys: metadata.required,
      fieldValidators: metadata.validators,
      fieldDecoders: metadata.decoders,
      validateFields: { validateDecodedFields($0, validate: validateWireFields) },
      fixedBody: nil,
      bodyIsNil: true,
      severity: nil,
      unit: unit.rawValue,
      description: description.rawValue,
      maximumSeries: maximumSeries
    )
  }
}

public enum TelemetryDeploymentEnvironment: String, CaseIterable, Sendable {
  case development
  case test
  case staging
  case production
}

public struct TelemetryResourceValue: Sendable {
  package let identity: TelemetryContractIdentity
  package let attributes: [String: AttributeValue]
}

public enum TelemetryResourceMode: Sendable {
  case native(environment: TelemetryDeploymentEnvironment)
  case strict(TelemetryResourceValue)
}

public struct TelemetryResourceDefinition<Payload: Sendable>: @unchecked Sendable {
  public let name: TelemetryContractName
  private let fields: [TelemetryField<Payload>]
  private let validatePayload: @Sendable (Payload) -> Bool
  private let validateWireFields: @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool
  package let identity: TelemetryContractIdentity

  public init(
    name: TelemetryContractName,
    fields: [TelemetryField<Payload>],
    validate: @escaping @Sendable (Payload) -> Bool = { _ in true },
    validationRule: TelemetryContractName? = nil,
    validateFields: @escaping @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool = {
      _ in true
    }
  ) throws {
    self.name = name
    self.fields = fields
    validatePayload = validate
    validateWireFields = validateFields
    identity = try validatedDefinition(
      kind: .resource,
      name: name,
      fields: fields,
      suffix: "resource:\(validationRule?.rawValue ?? "none")"
    )
  }

  public func makeValue(_ payload: Payload) throws -> TelemetryResourceValue {
    guard validatePayload(payload) else {
      throw TelemetryContractError.invalidPayload(field: nil)
    }
    var attributes: [String: AttributeValue] = [:]
    for field in fields {
      if let (key, value) = try field.extract(from: payload) {
        attributes[key] = value
      }
    }
    guard schema.validatesFields(attributes) else {
      throw TelemetryContractError.invalidPayload(field: nil)
    }
    guard
      case .string(let environment)? = attributes["deployment.environment.name"],
      TelemetryDeploymentEnvironment(rawValue: environment) != nil
    else {
      throw TelemetryContractError.invalidPayload(
        field: try TelemetryFieldKey("deployment.environment.name")
      )
    }
    return TelemetryResourceValue(identity: identity, attributes: attributes)
  }

  package var schema: TelemetryContractRecordSchema {
    let metadata = fieldMetadata(fields)
    return TelemetryContractRecordSchema(
      identity: identity,
      fieldKeys: metadata.keys,
      requiredKeys: metadata.required,
      fieldValidators: metadata.validators,
      fieldDecoders: metadata.decoders,
      validateFields: { validateDecodedFields($0, validate: validateWireFields) },
      fixedBody: nil,
      bodyIsNil: true,
      severity: nil,
      unit: nil,
      description: nil,
      maximumSeries: nil
    )
  }
}

public struct AnyTelemetrySpanDefinition: Sendable {
  package let schema: TelemetryContractRecordSchema
  public init<Payload>(_ definition: TelemetrySpanDefinition<Payload>) {
    schema = definition.schema
  }
}

public struct AnyTelemetryLogDefinition: Sendable {
  package let schema: TelemetryContractRecordSchema
  public init<Payload>(_ definition: TelemetryLogDefinition<Payload>) {
    schema = definition.schema
  }
}

public struct AnyTelemetryOperationalEventDefinition: Sendable {
  package let schema: TelemetryContractRecordSchema
  public init<Payload>(_ definition: TelemetryOperationalEventDefinition<Payload>) {
    schema = definition.schema
  }
}

public struct AnyTelemetryCounterDefinition: Sendable {
  package let schema: TelemetryContractRecordSchema
  public init<Payload>(_ definition: TelemetryCounterDefinition<Payload>) {
    schema = definition.schema
  }
}

public struct AnyTelemetryResourceDefinition: Sendable {
  package let schema: TelemetryContractRecordSchema
  public init<Payload>(_ definition: TelemetryResourceDefinition<Payload>) {
    schema = definition.schema
  }
}

public struct TelemetryContractCatalog: Sendable {
  public static let contractVersionKey = "telemetry.contract.version"
  public static let empty = try! TelemetryContractCatalog(contractVersion: .init(1))

  public let contractVersion: TelemetryContractVersion
  package let spans: [String: TelemetryContractRecordSchema]
  package let logs: [String: TelemetryContractRecordSchema]
  package let operationalEvents: [String: TelemetryContractRecordSchema]
  package let counters: [String: TelemetryContractRecordSchema]
  package let resources: [TelemetryContractIdentity: TelemetryContractRecordSchema]

  public init(
    contractVersion: TelemetryContractVersion,
    spans: [AnyTelemetrySpanDefinition] = [],
    logs: [AnyTelemetryLogDefinition] = [],
    counters: [AnyTelemetryCounterDefinition] = [],
    resources: [AnyTelemetryResourceDefinition] = []
  ) throws {
    try self.init(
      contractVersion: contractVersion,
      spans: spans,
      logs: logs,
      operationalEvents: [],
      counters: counters,
      resources: resources
    )
  }

  public init(
    contractVersion: TelemetryContractVersion,
    spans: [AnyTelemetrySpanDefinition] = [],
    logs: [AnyTelemetryLogDefinition] = [],
    operationalEvents: [AnyTelemetryOperationalEventDefinition],
    counters: [AnyTelemetryCounterDefinition] = [],
    resources: [AnyTelemetryResourceDefinition] = []
  ) throws {
    guard
      spans.count <= 64,
      logs.count <= 64,
      operationalEvents.count <= 64,
      counters.count <= 32,
      resources.count <= 1
    else {
      throw TelemetryContractError.invalidDefinition
    }
    let reservedNames =
      Set([
        ComposableOTelSemantics.Spans.reducer,
        ComposableOTelSemantics.Spans.effect,
        ComposableOTelSemantics.Spans.dependency,
        ComposableOTelSemantics.Spans.navigation,
        ComposableOTelSemantics.Spans.unknown,
        ComposableOTelSemantics.Events.effectStarted,
        ComposableOTelSemantics.Events.effectCompleted,
        ComposableOTelSemantics.Events.effectCancelled,
        ComposableOTelSemantics.Events.exception,
        ComposableOTelSemantics.Events.navigationChanged,
      ])
      .union(ComposableOTelSemantics.Metrics.all)
    guard
      spans.allSatisfy({ !reservedNames.contains($0.schema.identity.name) }),
      logs.allSatisfy({ !reservedNames.contains($0.schema.identity.name) }),
      operationalEvents.allSatisfy({ !reservedNames.contains($0.schema.identity.name) }),
      counters.allSatisfy({ !reservedNames.contains($0.schema.identity.name) }),
      resources.allSatisfy({
        $0.schema.requiredKeys.contains("deployment.environment.name")
      })
    else {
      throw TelemetryContractError.invalidDefinition
    }

    self.contractVersion = contractVersion
    self.spans = try Self.records(spans.map(\.schema))
    self.logs = try Self.records(logs.map(\.schema))
    self.operationalEvents = try Self.records(operationalEvents.map(\.schema))
    self.counters = try Self.records(counters.map(\.schema))
    self.resources = try Self.resources(resources.map(\.schema))
    guard Set(self.logs.keys).isDisjoint(with: self.operationalEvents.keys) else {
      throw TelemetryContractError.duplicateDefinition
    }
  }

  package func contains(_ identity: TelemetryContractIdentity) -> Bool {
    switch identity.kind {
    case .span: spans[identity.name]?.identity == identity
    case .log: logs[identity.name]?.identity == identity
    case .operationalEvent: operationalEvents[identity.name]?.identity == identity
    case .counter: counters[identity.name]?.identity == identity
    case .resource: resources[identity] != nil
    }
  }

  package func resourceSchema(
    for identity: TelemetryContractIdentity
  ) -> TelemetryContractRecordSchema? {
    resources[identity]
  }

  private static func records(
    _ schemas: [TelemetryContractRecordSchema]
  ) throws -> [String: TelemetryContractRecordSchema] {
    var result: [String: TelemetryContractRecordSchema] = [:]
    for schema in schemas {
      guard result[schema.identity.name] == nil else {
        throw TelemetryContractError.duplicateDefinition
      }
      result[schema.identity.name] = schema
    }
    return result
  }

  private static func resources(
    _ schemas: [TelemetryContractRecordSchema]
  ) throws -> [TelemetryContractIdentity: TelemetryContractRecordSchema] {
    var result: [TelemetryContractIdentity: TelemetryContractRecordSchema] = [:]
    for schema in schemas {
      guard result[schema.identity] == nil else {
        throw TelemetryContractError.duplicateDefinition
      }
      result[schema.identity] = schema
    }
    return result
  }
}

package final class TelemetryContractRuntime: @unchecked Sendable {
  package static let empty = TelemetryContractRuntime(
    catalog: .empty,
    counters: [:],
    providerRetention: nil
  )

  package let catalog: TelemetryContractCatalog
  private let counters: [TelemetryContractIdentity: any LongCounter]
  private let providerRetention: AnyObject?

  package init(
    catalog: TelemetryContractCatalog,
    counters: [TelemetryContractIdentity: any LongCounter],
    providerRetention: AnyObject?
  ) {
    self.catalog = catalog
    self.counters = counters
    self.providerRetention = providerRetention
  }

  package func counter(
    for identity: TelemetryContractIdentity
  ) -> (any LongCounter)? {
    counters[identity]
  }
}

extension TelemetryClient {
  public func withSpan<Payload: Sendable, Result: Sendable>(
    _ definition: TelemetrySpanDefinition<Payload>,
    payload: Payload,
    operation: @escaping @Sendable () async throws -> Result
  ) async throws -> Result {
    guard policy.signals.tracesEnabled else {
      return try await operation()
    }
    guard contracts.catalog.contains(definition.identity) else {
      throw TelemetryContractError.unregisteredDefinition
    }
    let attributes = try definition.attributes(
      for: payload,
      version: contracts.catalog.contractVersion
    )
    return
      try await tracer
      .spanBuilder(spanName: definition.name.rawValue)
      .setSpanKind(spanKind: .internal)
      .setAttributes(attributes)
      .withActiveSpan { span in
        do {
          let result = try await operation()
          span.status = .ok
          return result
        } catch {
          if error is CancellationError {
            span.status = .unset
            span.addEvent(name: ComposableOTelSemantics.Events.effectCancelled)
          } else {
            span.status = .error(description: "Operation failed")
            span.addEvent(
              name: ComposableOTelSemantics.Events.exception,
              attributes: telemetryErrorAttributes(for: error)
            )
          }
          throw error
        }
      }
  }

  public func withSynchronousSpan<Payload: Sendable, Result: Sendable>(
    _ definition: TelemetrySpanDefinition<Payload>,
    payload: Payload,
    operation: @Sendable () throws -> Result
  ) throws -> Result {
    guard policy.signals.tracesEnabled else {
      return try operation()
    }
    guard contracts.catalog.contains(definition.identity) else {
      throw TelemetryContractError.unregisteredDefinition
    }
    let attributes = try definition.attributes(
      for: payload,
      version: contracts.catalog.contractVersion
    )

    return
      try tracer
      .spanBuilder(spanName: definition.name.rawValue)
      .setSpanKind(spanKind: .internal)
      .setAttributes(attributes)
      .withActiveSpan { span in
        do {
          let result = try operation()
          span.status = .ok
          return result
        } catch {
          if error is CancellationError {
            span.status = .unset
            span.addEvent(name: ComposableOTelSemantics.Events.effectCancelled)
          } else {
            span.status = .error(description: "Operation failed")
            span.addEvent(
              name: ComposableOTelSemantics.Events.exception,
              attributes: telemetryErrorAttributes(for: error)
            )
          }
          throw error
        }
      }
  }

  public func record<Payload: Sendable>(
    _ definition: TelemetryLogDefinition<Payload>,
    payload: Payload
  ) throws {
    guard policy.signals.logsEnabled else { return }
    guard contracts.catalog.contains(definition.identity) else {
      throw TelemetryContractError.unregisteredDefinition
    }
    let attributes = try definition.attributes(
      for: payload,
      version: contracts.catalog.contractVersion
    )
    let builder = logger.logRecordBuilder()
      .setSeverity(definition.severity.otelSeverity)
      .setAttributes(attributes)
      .setEventName(definition.eventName.rawValue)
    if let body = definition.body {
      _ = builder.setBody(body)
    }
    builder.emit()
  }

  /// Synchronously validates and records a registered operational event.
  ///
  /// Acceptance into a production runtime occurs on the caller before this method returns. Export
  /// remains asynchronous and bounded by the runtime's log batch configuration.
  public func record<Payload: Sendable>(
    _ definition: TelemetryOperationalEventDefinition<Payload>,
    payload: Payload
  ) throws {
    guard policy.signals.operationalEventsEnabled else { return }
    guard contracts.catalog.contains(definition.identity) else {
      throw TelemetryContractError.unregisteredDefinition
    }
    let attributes = try definition.attributes(
      for: payload,
      version: contracts.catalog.contractVersion
    )
    logger.logRecordBuilder()
      .setSeverity(Severity.info)
      .setAttributes(attributes)
      .setEventName(definition.eventName.rawValue)
      .emit()
  }

  public func add<Payload: Sendable>(
    _ definition: TelemetryCounterDefinition<Payload>,
    delta: TelemetryCounterDelta,
    payload: Payload
  ) throws {
    guard policy.signals.metricsEnabled else { return }
    guard contracts.catalog.contains(definition.identity) else {
      throw TelemetryContractError.unregisteredDefinition
    }
    let attributes = try definition.attributes(
      for: payload,
      version: contracts.catalog.contractVersion
    )
    guard var counter = contracts.counter(for: definition.identity) else {
      throw TelemetryContractError.unregisteredDefinition
    }
    counter.add(value: delta.rawValue, attributes: attributes)
  }
}
