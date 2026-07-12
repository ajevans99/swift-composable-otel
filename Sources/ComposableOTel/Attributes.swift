import OpenTelemetryApi

/// Stable attribute keys used by ComposableOTel semantic conventions.
public enum TCAAttributes {
  public static let featureName = "tca.feature.name"
  public static let actionName = "tca.action.name"
  public static let stateChanged = "tca.state.changed"
  public static let reducerDurationMs = "tca.reducer.duration_ms"
  public static let effectName = "tca.effect.name"
  public static let effectCancelled = "tca.effect.cancelled"
  public static let effectLongLived = "tca.effect.long_lived"
  public static let effectMarker = "tca.effect.marker"
  public static let effectOutcome = "tca.effect.outcome"
  public static let dependencyName = "tca.dependency.name"
  public static let operationName = "tca.operation.name"
  public static let dependencyError = "tca.dependency.error"
  public static let errorType = "error.type"
  public static let errorCategory = "error.category"
  public static let errorCode = "error.code"
  public static let errorHandled = "error.handled"
  public static let errorRetryable = "error.retryable"
  public static let navigationOperation = "tca.navigation.operation"
  public static let navigationRoute = "tca.navigation.route"
}

extension SpanBuilder {
  @discardableResult
  func setAttributes(_ attributes: [String: AttributeValue]) -> Self {
    for (key, value) in attributes {
      setAttribute(key: key, value: value)
    }
    return self
  }
}
