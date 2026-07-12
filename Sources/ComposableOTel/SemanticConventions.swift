/// Stable names and field sets owned by ComposableOTel.
public enum ComposableOTelSemantics {
  public enum Spans {
    public static let reducer = "tca.reducer"
    public static let effect = "tca.effect"
    public static let dependency = "tca.dependency"
    public static let navigation = "tca.navigation"
    public static let unknown = "otel.span"
  }

  public enum Events {
    public static let effectStarted = "tca.effect.started"
    public static let effectCompleted = "tca.effect.completed"
    public static let effectCancelled = "tca.effect.cancelled"
    public static let exception = "exception"
    public static let navigationChanged = "tca.navigation.changed"
  }

  public enum LogBodies {
    public static let actionDispatched = "Action dispatched"
    public static let effectFailed = "Effect failed"
    public static let dependencyFailed = "Dependency call failed"
    public static let navigationChanged = "Navigation changed"
    public static let unknown = "Telemetry event"
  }

  public enum Metrics {
    public static let actionsDispatched = "tca.actions.dispatched"
    public static let effectsStarted = "tca.effects.started"
    public static let effectsCompleted = "tca.effects.completed"
    public static let effectsCancelled = "tca.effects.cancelled"
    public static let effectsErrored = "tca.effects.errored"
    public static let dependenciesCalled = "tca.dependencies.called"
    public static let dependenciesErrored = "tca.dependencies.errored"
    public static let navigationTransitions = "tca.navigation.transitions"
    public static let reducerDuration = "tca.reducer.duration"
    public static let effectDuration = "tca.effect.duration"
    public static let dependencyDuration = "tca.dependency.duration"
    public static let activeEffects = "tca.store.active_effects"

    public static let all: Set<String> = [
      actionsDispatched,
      effectsStarted,
      effectsCompleted,
      effectsCancelled,
      effectsErrored,
      dependenciesCalled,
      dependenciesErrored,
      navigationTransitions,
      reducerDuration,
      effectDuration,
      dependencyDuration,
      activeEffects,
    ]

    public static func attributeKeys(for name: String) -> Set<String> {
      switch name {
      case actionsDispatched, reducerDuration:
        return [TCAAttributes.featureName, TCAAttributes.actionName]
      case effectsStarted, effectsCompleted, effectsCancelled, effectsErrored, effectDuration,
        activeEffects:
        return [TCAAttributes.effectName, TCAAttributes.effectLongLived]
      case dependenciesCalled, dependenciesErrored, dependencyDuration:
        return [TCAAttributes.dependencyName, TCAAttributes.operationName]
      case navigationTransitions:
        return [TCAAttributes.navigationOperation, TCAAttributes.navigationRoute]
      default:
        return []
      }
    }
  }
}
