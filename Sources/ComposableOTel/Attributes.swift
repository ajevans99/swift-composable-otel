import OpenTelemetryApi

/// Attribute key constants used across ComposableOTel instrumentation.
public enum TCAAttributes {
  // MARK: - Reducer

  public static let reducerName = "tca.reducer.name"
  public static let actionType = "tca.action.type"
  public static let actionScoped = "tca.action.scoped"
  public static let stateChanged = "tca.state.changed"
  public static let reducerDurationMs = "tca.reducer.duration_ms"

  // MARK: - Effect

  public static let effectName = "tca.effect.name"
  public static let effectCancelled = "tca.effect.cancelled"
  public static let effectActionsEmitted = "tca.effect.actions_emitted"
  public static let effectLongLived = "tca.effect.long_lived"

  // MARK: - Dependency

  public static let dependencyName = "tca.dependency.name"
  public static let dependencyMethod = "tca.dependency.method"
  public static let dependencyError = "tca.dependency.error"

  // MARK: - Error

  public static let errorType = "error.type"
  public static let errorRedacted = "tca.error.redacted"

  // MARK: - Navigation

  public static let navigationPush = "navigation.push"
  public static let navigationPop = "navigation.pop"
  public static let navigationPresent = "navigation.present"
  public static let navigationDismiss = "navigation.dismiss"
}
