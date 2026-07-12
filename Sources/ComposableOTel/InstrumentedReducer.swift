import ComposableArchitecture
import Dependencies
import Foundation
import OpenTelemetryApi

/// A reducer wrapper that emits bounded, privacy-safe OpenTelemetry signals.
public struct InstrumentedReducer<Base: Reducer>: Reducer {
  @usableFromInline let base: Base
  @usableFromInline let feature: FeatureID
  @usableFromInline let actionID: @Sendable (Base.Action) -> ActionID
  @usableFromInline let stateChangeToken: (@Sendable (Base.State) -> StateChangeToken)?

  @Dependency(\.composableOTel) var telemetry

  @inlinable
  public init(
    base: Base,
    feature: FeatureID,
    action: @escaping @Sendable (Base.Action) -> ActionID,
    stateChangeToken: (@Sendable (Base.State) -> StateChangeToken)? = nil
  ) {
    self.base = base
    self.feature = feature
    self.actionID = action
    self.stateChangeToken = stateChangeToken
  }

  public func _reduce(
    into state: inout Base.State,
    action: Base.Action
  ) -> Effect<Base.Action> {
    let feature = telemetry.policy.schema.bounded(feature)
    let boundedAction = telemetry.policy.schema.bounded(actionID(action))
    let attributes: [String: AttributeValue] = [
      TCAAttributes.featureName: .string(feature.rawValue),
      TCAAttributes.actionName: .string(boundedAction.rawValue),
    ]
    let clock = ContinuousClock()
    let startTime = clock.now

    let effect: Effect<Base.Action>
    let duration: Double
    if telemetry.policy.signals.tracesEnabled {
      let oldToken = stateChangeToken?(state)
      let spanBuilder = telemetry.tracer
        .spanBuilder(spanName: ComposableOTelSemantics.Spans.reducer)
        .setSpanKind(spanKind: .internal)
        .setAttributes(telemetry.policy.sanitizedSpanAttributes(attributes))

      let traced = spanBuilder.withActiveSpan { span in
        let effect = ReducerTraceContext.$spanContext.withValue(span.context) {
          base._reduce(into: &state, action: action)
        }
        if let oldToken, let newToken = stateChangeToken?(state) {
          span.setAttribute(key: TCAAttributes.stateChanged, value: oldToken != newToken)
        }
        let duration = durationMilliseconds(from: startTime, clock: clock)
        span.setAttribute(
          key: TCAAttributes.reducerDurationMs,
          value: duration
        )
        span.status = .ok
        return (effect: effect, duration: duration)
      }
      effect = traced.effect
      duration = traced.duration
    } else {
      effect = base._reduce(into: &state, action: action)
      duration = durationMilliseconds(from: startTime, clock: clock)
    }

    if telemetry.policy.signals.metricsEnabled {
      let metricAttributes = telemetry.policy.sanitizedMetricAttributes(
        attributes,
        instrumentName: ComposableOTelSemantics.Metrics.actionsDispatched
      )
      var actionsCounter = telemetry.metrics.actionsDispatched
      actionsCounter.add(value: 1, attributes: metricAttributes)
      var durationHistogram = telemetry.metrics.reducerDuration
      durationHistogram.record(value: duration, attributes: metricAttributes)
    }

    telemetry.emitLog(
      severity: .info,
      body: ComposableOTelSemantics.LogBodies.actionDispatched,
      attributes: attributes.merging([
        TCAAttributes.reducerDurationMs: .double(duration)
      ]) { _, new in new }
    )
    return effect
  }
}

extension Reducer {
  /// Wraps this reducer with bounded OpenTelemetry instrumentation.
  ///
  /// The feature and action IDs are always schema-bounded; the action value is never reflected or
  /// described. Supply `stateChangeToken` only when a non-sensitive version or fingerprint is
  /// already available. The token is compared in memory and never exported.
  public func instrumented(
    feature: FeatureID,
    action: @escaping @Sendable (Action) -> ActionID,
    stateChangeToken: (@Sendable (State) -> StateChangeToken)? = nil
  ) -> InstrumentedReducer<Self> {
    InstrumentedReducer(
      base: self,
      feature: feature,
      action: action,
      stateChangeToken: stateChangeToken
    )
  }
}

func durationMilliseconds(from start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
  let elapsed = clock.now - start
  return Double(elapsed.components.seconds) * 1_000
    + Double(elapsed.components.attoseconds) / 1e15
}
