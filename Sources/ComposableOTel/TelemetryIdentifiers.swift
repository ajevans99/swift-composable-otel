/// A marker protocol used to keep telemetry identifier domains type-safe.
public protocol TelemetryIdentifierKind: Sendable {
  static var allowsLeadingDigit: Bool { get }
  static var allowsUppercaseLetters: Bool { get }
  static var allowsPlusSign: Bool { get }
}

extension TelemetryIdentifierKind {
  public static var allowsLeadingDigit: Bool { false }
  public static var allowsUppercaseLetters: Bool { false }
  public static var allowsPlusSign: Bool { false }
}

/// A validated, bounded semantic identifier.
///
/// Identifiers contain 1 through 48 lowercase ASCII characters. The first character must be a
/// letter; remaining characters may also contain digits, `.`, `_`, or `-`. Prefer string literals
/// or static constants. Use ``init(validating:)`` only when loading trusted static configuration.
public struct TelemetryIdentifier<Kind: TelemetryIdentifierKind>:
  Hashable, RawRepresentable, Sendable, ExpressibleByStringLiteral
{
  public static var maximumLength: Int { 48 }

  public let rawValue: String

  public init?(rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  public init?(validating value: String) {
    self.init(rawValue: value)
  }

  public init(stringLiteral value: String) {
    guard let identifier = Self(rawValue: value) else {
      preconditionFailure("Invalid telemetry identifier literal")
    }
    self = identifier
  }

  /// The deterministic aggregation value for identifiers outside the configured schema.
  public static var other: Self { "other" }

  private static func isValid(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard 1...maximumLength ~= bytes.count, let first = bytes.first,
      first.isLowercaseLetter || (Kind.allowsLeadingDigit && first.isDigit)
    else {
      return false
    }
    return bytes.dropFirst().allSatisfy {
      $0.isLowercaseLetter || (Kind.allowsUppercaseLetters && $0.isUppercaseLetter)
        || $0.isDigit || $0 == 45 || $0 == 46 || $0 == 95 || (Kind.allowsPlusSign && $0 == 43)
    }
  }
}

extension UInt8 {
  fileprivate var isLowercaseLetter: Bool { 97...122 ~= self }
  fileprivate var isUppercaseLetter: Bool { 65...90 ~= self }
  fileprivate var isDigit: Bool { 48...57 ~= self }
}

public enum FeatureIdentifierKind: TelemetryIdentifierKind {}
public enum ActionIdentifierKind: TelemetryIdentifierKind {}
public enum EffectIdentifierKind: TelemetryIdentifierKind {}
public enum DependencyIdentifierKind: TelemetryIdentifierKind {}
public enum OperationIdentifierKind: TelemetryIdentifierKind {}
public enum RouteIdentifierKind: TelemetryIdentifierKind {}
public enum ErrorTypeIdentifierKind: TelemetryIdentifierKind {}
public enum ErrorCategoryIdentifierKind: TelemetryIdentifierKind {}
public enum ErrorCodeIdentifierKind: TelemetryIdentifierKind {}
public enum ServiceIdentifierKind: TelemetryIdentifierKind {}
public enum ServiceVersionIdentifierKind: TelemetryIdentifierKind {
  public static let allowsLeadingDigit = true
  public static let allowsUppercaseLetters = true
  public static let allowsPlusSign = true
}

public typealias FeatureID = TelemetryIdentifier<FeatureIdentifierKind>
public typealias ActionID = TelemetryIdentifier<ActionIdentifierKind>
public typealias EffectID = TelemetryIdentifier<EffectIdentifierKind>
public typealias DependencyID = TelemetryIdentifier<DependencyIdentifierKind>
public typealias OperationID = TelemetryIdentifier<OperationIdentifierKind>
public typealias RouteID = TelemetryIdentifier<RouteIdentifierKind>
public typealias ErrorTypeID = TelemetryIdentifier<ErrorTypeIdentifierKind>
public typealias ErrorCategoryID = TelemetryIdentifier<ErrorCategoryIdentifierKind>
public typealias ErrorCodeID = TelemetryIdentifier<ErrorCodeIdentifierKind>
public typealias ServiceID = TelemetryIdentifier<ServiceIdentifierKind>
public typealias ServiceVersionID = TelemetryIdentifier<ServiceVersionIdentifierKind>

/// Stable terminal outcomes emitted by package instrumentation.
public enum TelemetryOutcome: String, CaseIterable, Sendable {
  case success
  case cancelled
  case error
}

/// Stable navigation operations for route telemetry.
public enum NavigationOperation: String, CaseIterable, Sendable {
  case push
  case pop
  case present
  case dismiss
}

/// An opaque, non-exported token used only to compare state before and after reduction.
public struct StateChangeToken: Equatable, Sendable {
  private let value: UInt64

  public init(_ value: UInt64) {
    self.value = value
  }
}

/// Independent controls for package-owned traces, metrics, and logs.
public struct TelemetrySignalConfiguration: Sendable {
  public var tracesEnabled: Bool
  public var metricsEnabled: Bool
  public var logsEnabled: Bool

  public init(
    tracesEnabled: Bool = true,
    metricsEnabled: Bool = true,
    logsEnabled: Bool = false
  ) {
    self.tracesEnabled = tracesEnabled
    self.metricsEnabled = metricsEnabled
    self.logsEnabled = logsEnabled
  }

  public static let disabled = Self(
    tracesEnabled: false,
    metricsEnabled: false,
    logsEnabled: false
  )
}

/// Bounded, production-safe error metadata.
///
/// Raw descriptions, localized text, backend bodies, stack traces, and payloads are never fields in
/// this type.
public struct TelemetryErrorMetadata: Sendable {
  public var type: ErrorTypeID
  public var category: ErrorCategoryID
  public var code: ErrorCodeID?
  public var handled: Bool
  public var retryable: Bool

  public init(
    type: ErrorTypeID = .other,
    category: ErrorCategoryID = .other,
    code: ErrorCodeID? = nil,
    handled: Bool = false,
    retryable: Bool = false
  ) {
    self.type = type
    self.category = category
    self.code = code
    self.handled = handled
    self.retryable = retryable
  }
}

/// A finite allowlist for every semantic identifier domain.
///
/// Identifiers not present in the schema deterministically aggregate to `other`. Construction
/// rejects schemas above package cardinality limits without including rejected values in errors.
public struct TelemetrySchema: Sendable {
  public enum Domain: String, Sendable {
    case features
    case actions
    case effects
    case dependencies
    case operations
    case routes
    case errorTypes = "error-types"
    case errorCategories = "error-categories"
    case errorCodes = "error-codes"
    case services
    case serviceVersions = "service-versions"
  }

  public enum ValidationError: Error, Equatable, Sendable {
    case cardinalityLimitExceeded(domain: Domain, limit: Int)
  }

  public static let featureLimit = 32
  public static let actionLimit = 128
  public static let effectLimit = 64
  public static let dependencyLimit = 64
  public static let operationLimit = 128
  public static let routeLimit = 64
  public static let errorTypeLimit = 32
  public static let errorCategoryLimit = 32
  public static let errorCodeLimit = 64
  public static let serviceLimit = 8
  public static let serviceVersionLimit = 16

  private let features: Set<FeatureID>
  private let actions: Set<ActionID>
  private let effects: Set<EffectID>
  private let dependencies: Set<DependencyID>
  private let operations: Set<OperationID>
  private let routes: Set<RouteID>
  private let errorTypes: Set<ErrorTypeID>
  private let errorCategories: Set<ErrorCategoryID>
  private let errorCodes: Set<ErrorCodeID>
  private let services: Set<ServiceID>
  private let serviceVersions: Set<ServiceVersionID>

  public init(
    features: [FeatureID] = [],
    actions: [ActionID] = [],
    effects: [EffectID] = [],
    dependencies: [DependencyID] = [],
    operations: [OperationID] = [],
    routes: [RouteID] = [],
    errorTypes: [ErrorTypeID] = [],
    errorCategories: [ErrorCategoryID] = [],
    errorCodes: [ErrorCodeID] = [],
    services: [ServiceID] = [],
    serviceVersions: [ServiceVersionID] = []
  ) throws {
    self.features = try Self.validated(features, limit: Self.featureLimit, domain: .features)
    self.actions = try Self.validated(actions, limit: Self.actionLimit, domain: .actions)
    self.effects = try Self.validated(effects, limit: Self.effectLimit, domain: .effects)
    self.dependencies = try Self.validated(
      dependencies,
      limit: Self.dependencyLimit,
      domain: .dependencies
    )
    self.operations = try Self.validated(
      operations,
      limit: Self.operationLimit,
      domain: .operations
    )
    self.routes = try Self.validated(routes, limit: Self.routeLimit, domain: .routes)
    self.errorTypes = try Self.validated(
      errorTypes,
      limit: Self.errorTypeLimit,
      domain: .errorTypes
    )
    self.errorCategories = try Self.validated(
      errorCategories,
      limit: Self.errorCategoryLimit,
      domain: .errorCategories
    )
    self.errorCodes = try Self.validated(
      errorCodes,
      limit: Self.errorCodeLimit,
      domain: .errorCodes
    )
    self.services = try Self.validated(services, limit: Self.serviceLimit, domain: .services)
    self.serviceVersions = try Self.validated(
      serviceVersions,
      limit: Self.serviceVersionLimit,
      domain: .serviceVersions
    )
  }

  public static let denyAll = try! Self()

  public func bounded(_ value: FeatureID) -> FeatureID {
    features.contains(value) ? value : .other
  }

  public func bounded(_ value: ActionID) -> ActionID {
    actions.contains(value) ? value : .other
  }

  public func bounded(_ value: EffectID) -> EffectID {
    effects.contains(value) ? value : .other
  }

  public func bounded(_ value: DependencyID) -> DependencyID {
    dependencies.contains(value) ? value : .other
  }

  public func bounded(_ value: OperationID) -> OperationID {
    operations.contains(value) ? value : .other
  }

  public func bounded(_ value: RouteID) -> RouteID {
    routes.contains(value) ? value : .other
  }

  public func bounded(_ value: ErrorTypeID) -> ErrorTypeID {
    errorTypes.contains(value) ? value : .other
  }

  public func bounded(_ value: ErrorCategoryID) -> ErrorCategoryID {
    errorCategories.contains(value) ? value : .other
  }

  public func bounded(_ value: ErrorCodeID) -> ErrorCodeID {
    errorCodes.contains(value) ? value : .other
  }

  public func bounded(_ value: ServiceID) -> ServiceID {
    services.contains(value) ? value : .other
  }

  public func bounded(_ value: ServiceVersionID) -> ServiceVersionID {
    serviceVersions.contains(value) ? value : .other
  }

  private static func validated<ID: Hashable>(
    _ values: [ID],
    limit: Int,
    domain: Domain
  ) throws -> Set<ID> {
    let values = Set(values)
    guard values.count <= limit else {
      throw ValidationError.cardinalityLimitExceeded(domain: domain, limit: limit)
    }
    return values
  }
}
