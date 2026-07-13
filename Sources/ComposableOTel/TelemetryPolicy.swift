import OpenTelemetryApi

/// Allowlist-first privacy and cardinality policy for package-owned telemetry.
public struct TelemetryPolicy: Sendable {
  public let schema: TelemetrySchema
  public let catalog: TelemetryContractCatalog
  public let signals: TelemetrySignalConfiguration
  private let classifyError: @Sendable (any Error) -> TelemetryErrorMetadata

  public init(
    schema: TelemetrySchema = .denyAll,
    catalog: TelemetryContractCatalog = .empty,
    signals: TelemetrySignalConfiguration = .init(),
    classifyError: @escaping @Sendable (any Error) -> TelemetryErrorMetadata = { _ in .init() }
  ) {
    self.schema = schema
    self.catalog = catalog
    self.signals = signals
    self.classifyError = classifyError
  }

  public func errorMetadata(for error: any Error) -> TelemetryErrorMetadata {
    let metadata = classifyError(error)
    return TelemetryErrorMetadata(
      type: schema.bounded(metadata.type),
      category: schema.bounded(metadata.category),
      code: metadata.code.map(schema.bounded),
      handled: metadata.handled,
      retryable: metadata.retryable
    )
  }

  package func sanitizedSpanName(_ name: String) -> String {
    switch name {
    case ComposableOTelSemantics.Spans.reducer,
      ComposableOTelSemantics.Spans.effect,
      ComposableOTelSemantics.Spans.dependency,
      ComposableOTelSemantics.Spans.navigation:
      return name
    default:
      return catalog.spans[name] == nil ? ComposableOTelSemantics.Spans.unknown : name
    }
  }

  package func sanitizedEventName(_ name: String) -> String? {
    switch name {
    case ComposableOTelSemantics.Events.effectStarted,
      ComposableOTelSemantics.Events.effectCompleted,
      ComposableOTelSemantics.Events.effectCancelled,
      ComposableOTelSemantics.Events.exception,
      ComposableOTelSemantics.Events.navigationChanged:
      return name
    default:
      return nil
    }
  }

  package func sanitizedLogBody(_ body: AttributeValue?) -> AttributeValue {
    guard case .string(let body) = body else {
      return .string(ComposableOTelSemantics.LogBodies.unknown)
    }
    switch body {
    case ComposableOTelSemantics.LogBodies.actionDispatched,
      ComposableOTelSemantics.LogBodies.effectFailed,
      ComposableOTelSemantics.LogBodies.dependencyFailed,
      ComposableOTelSemantics.LogBodies.navigationChanged:
      return .string(body)
    default:
      return .string(ComposableOTelSemantics.LogBodies.unknown)
    }
  }

  package func sanitizedSpanAttributes(
    _ attributes: [String: AttributeValue]
  ) -> [String: AttributeValue] {
    sanitizedAttributes(attributes)
  }

  package func sanitizedLogAttributes(
    _ attributes: [String: AttributeValue]
  ) -> [String: AttributeValue] {
    sanitizedAttributes(attributes)
  }

  package func sanitizedMetricAttributes(
    _ attributes: [String: AttributeValue],
    instrumentName: String
  ) -> [String: AttributeValue] {
    let allowedKeys = ComposableOTelSemantics.Metrics.attributeKeys(for: instrumentName)
    return sanitizedAttributes(attributes.filter { allowedKeys.contains($0.key) })
  }

  package func sanitizedResourceAttributes(
    _ attributes: [String: AttributeValue]
  ) -> [String: AttributeValue] {
    if attributes[TelemetryContractCatalog.contractVersionKey] != nil {
      guard
        let resourceSchema = catalog.resources.values.first,
        Set(attributes.keys) == resourceSchema.fieldKeys,
        let sanitized = resourceSchema.sanitizedAttributes(
          attributes,
          version: catalog.contractVersion
        )
      else {
        return [:]
      }
      return sanitized
    }

    var result: [String: AttributeValue] = [
      "telemetry.sdk.name": .string("opentelemetry"),
      "telemetry.sdk.language": .string("swift"),
      "telemetry.distro.name": .string(ComposableOTelMetadata.packageName),
      "telemetry.distro.version": .string(ComposableOTelMetadata.version),
    ]

    if let value = attributes["service.name"] {
      if case .string(let rawValue) = value, let identifier = ServiceID(validating: rawValue) {
        result["service.name"] = .string(schema.bounded(identifier).rawValue)
      } else {
        result["service.name"] = .string(ServiceID.other.rawValue)
      }
    }
    if let value = attributes["service.version"] {
      if case .string(let rawValue) = value,
        let identifier = ServiceVersionID(validating: rawValue)
      {
        result["service.version"] = .string(schema.bounded(identifier).rawValue)
      } else {
        result["service.version"] = .string(ServiceVersionID.other.rawValue)
      }
    }
    if case .string(let value) = attributes["deployment.environment.name"],
      TelemetryDeploymentEnvironment(rawValue: value) != nil
    {
      result["deployment.environment.name"] = .string(value)
    }
    if attributes["os.type"] == .string("darwin") {
      result["os.type"] = .string("darwin")
    }
    return result
  }

  private func sanitizedAttributes(
    _ attributes: [String: AttributeValue]
  ) -> [String: AttributeValue] {
    var result: [String: AttributeValue] = [:]
    for (key, value) in attributes {
      switch key {
      case TCAAttributes.featureName:
        result[key] = boundedString(value, as: FeatureID.self, schema.bounded)
      case TCAAttributes.actionName:
        result[key] = boundedString(value, as: ActionID.self, schema.bounded)
      case TCAAttributes.effectName:
        result[key] = boundedString(value, as: EffectID.self, schema.bounded)
      case TCAAttributes.dependencyName:
        result[key] = boundedString(value, as: DependencyID.self, schema.bounded)
      case TCAAttributes.operationName:
        result[key] = boundedString(value, as: OperationID.self, schema.bounded)
      case TCAAttributes.navigationRoute:
        result[key] = boundedString(value, as: RouteID.self, schema.bounded)
      case TCAAttributes.errorType:
        result[key] = boundedString(value, as: ErrorTypeID.self, schema.bounded)
      case TCAAttributes.errorCategory:
        result[key] = boundedString(value, as: ErrorCategoryID.self, schema.bounded)
      case TCAAttributes.errorCode:
        result[key] = boundedString(value, as: ErrorCodeID.self, schema.bounded)
      case TCAAttributes.effectOutcome:
        if case .string(let rawValue) = value,
          TelemetryOutcome(rawValue: rawValue) != nil
        {
          result[key] = value
        }
      case TCAAttributes.navigationOperation:
        if case .string(let rawValue) = value,
          NavigationOperation(rawValue: rawValue) != nil
        {
          result[key] = value
        }
      case TCAAttributes.stateChanged,
        TCAAttributes.effectCancelled,
        TCAAttributes.effectLongLived,
        TCAAttributes.effectMarker,
        TCAAttributes.dependencyError,
        TCAAttributes.errorHandled,
        TCAAttributes.errorRetryable:
        if case .bool = value {
          result[key] = value
        }
      case TCAAttributes.reducerDurationMs:
        if case .double(let duration) = value, duration.isFinite, duration >= 0 {
          result[key] = .double(min(duration, 86_400_000))
        }
      default:
        break
      }
    }
    return result
  }

  private func boundedString<Kind: TelemetryIdentifierKind>(
    _ value: AttributeValue,
    as _: TelemetryIdentifier<Kind>.Type,
    _ bound: (TelemetryIdentifier<Kind>) -> TelemetryIdentifier<Kind>
  ) -> AttributeValue? {
    guard case .string(let rawValue) = value,
      let identifier = TelemetryIdentifier<Kind>(validating: rawValue)
    else {
      return .string(TelemetryIdentifier<Kind>.other.rawValue)
    }
    return .string(bound(identifier).rawValue)
  }
}
