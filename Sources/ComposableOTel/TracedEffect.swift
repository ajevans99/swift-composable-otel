import Dependencies
import Foundation
import OpenTelemetryApi

#if canImport(ComposableArchitecture)
  import ComposableArchitecture

  extension Effect {
    /// Adds a bounded initiation marker without observing the effect lifecycle.
    public func traceStart(effect: EffectID) -> Self {
      let parentContext = ReducerTraceContext.spanContext
      let signalEffect: Self = .run { _ in
        @Dependency(\.composableOTel) var telemetry

        let effect = telemetry.policy.schema.bounded(effect)
        let attributes: [String: AttributeValue] = [
          TCAAttributes.effectName: .string(effect.rawValue),
          TCAAttributes.effectLongLived: .bool(false),
          TCAAttributes.effectMarker: .bool(true),
        ]

        if telemetry.policy.signals.tracesEnabled {
          let spanBuilder = telemetry.tracer
            .spanBuilder(spanName: ComposableOTelSemantics.Spans.effect)
            .setSpanKind(spanKind: .internal)
            .setAttributes(telemetry.policy.sanitizedSpanAttributes(attributes))
          if let parentContext {
            spanBuilder.setParent(parentContext)
          } else {
            spanBuilder.setNoParent()
          }
          spanBuilder.withActiveSpan { span in
            span.status = .ok
            span.addEvent(name: ComposableOTelSemantics.Events.effectStarted)
          }
        }

        if telemetry.policy.signals.metricsEnabled {
          var counter = telemetry.metrics.effectsStarted
          counter.add(
            value: 1,
            attributes: telemetry.policy.sanitizedMetricAttributes(
              attributes,
              instrumentName: ComposableOTelSemantics.Metrics.effectsStarted
            )
          )
        }
      }
      return merge(with: signalEffect)
    }
  }

  extension Effect {
    /// Creates a one-shot effect with bounded lifecycle telemetry.
    public static func tracedRun(
      effect: EffectID,
      priority: TaskPriority? = nil,
      operation: @escaping @Sendable (Send<Action>) async throws -> Void
    ) -> Self {
      tracedRun(effect: effect, priority: priority, longLived: false, operation: operation)
    }

    /// Creates a long-lived effect with bounded lifecycle telemetry.
    public static func tracedLongLivedRun(
      effect: EffectID,
      priority: TaskPriority? = nil,
      operation: @escaping @Sendable (Send<Action>) async throws -> Void
    ) -> Self {
      tracedRun(effect: effect, priority: priority, longLived: true, operation: operation)
    }

    private static func tracedRun(
      effect: EffectID,
      priority: TaskPriority?,
      longLived: Bool,
      operation: @escaping @Sendable (Send<Action>) async throws -> Void
    ) -> Self {
      let parentContext = ReducerTraceContext.spanContext
      return .run(priority: priority, name: effect.rawValue) { send in
        @Dependency(\.composableOTel) var telemetry
        try await telemetry.withEffectTrace(
          effect: effect,
          longLived: longLived,
          parentContext: parentContext
        ) {
          try await operation(send)
        }
      }
    }
  }
#endif

extension TelemetryClient {
  func withEffectTrace<T: Sendable>(
    effect: EffectID,
    longLived: Bool,
    parentContext: SpanContext?,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let effect = policy.schema.bounded(effect)
    let attributes: [String: AttributeValue] = [
      TCAAttributes.effectName: .string(effect.rawValue),
      TCAAttributes.effectLongLived: .bool(longLived),
    ]
    let metricAttributes = policy.sanitizedMetricAttributes(
      attributes,
      instrumentName: ComposableOTelSemantics.Metrics.effectsStarted
    )

    if policy.signals.metricsEnabled {
      var startedCounter = metrics.effectsStarted
      startedCounter.add(value: 1, attributes: metricAttributes)
      var activeCounter = metrics.activeEffects
      activeCounter.add(value: 1, attributes: metricAttributes)
    }

    let clock = ContinuousClock()
    let startTime = clock.now

    if policy.signals.tracesEnabled {
      let spanBuilder =
        tracer
        .spanBuilder(spanName: ComposableOTelSemantics.Spans.effect)
        .setSpanKind(spanKind: .internal)
        .setAttributes(policy.sanitizedSpanAttributes(attributes))
      if let parentContext {
        spanBuilder.setParent(parentContext)
      } else {
        spanBuilder.setNoParent()
      }
      return try await spanBuilder.withActiveSpan { span in
        try await runEffectOperation(
          operation,
          effect: effect,
          attributes: metricAttributes,
          startTime: startTime,
          clock: clock,
          span: span
        )
      }
    }

    return try await runEffectOperation(
      operation,
      effect: effect,
      attributes: metricAttributes,
      startTime: startTime,
      clock: clock,
      span: nil
    )
  }

  private func runEffectOperation<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T,
    effect: EffectID,
    attributes: [String: AttributeValue],
    startTime: ContinuousClock.Instant,
    clock: ContinuousClock,
    span: (any SpanBase)?
  ) async throws -> T {
    defer {
      if policy.signals.metricsEnabled {
        var durationHistogram = metrics.effectDuration
        durationHistogram.record(
          value: durationMilliseconds(from: startTime, clock: clock),
          attributes: attributes
        )
        var activeCounter = metrics.activeEffects
        activeCounter.add(value: -1, attributes: attributes)
      }
    }

    do {
      let result = try await operation()
      recordEffectOutcome(.success, attributes: attributes, span: span)
      return result
    } catch {
      if error is CancellationError {
        recordEffectOutcome(.cancelled, attributes: attributes, span: span)
      } else {
        recordEffectError(error, effect: effect, attributes: attributes, span: span)
      }
      throw error
    }
  }

  private func recordEffectOutcome(
    _ outcome: TelemetryOutcome,
    attributes: [String: AttributeValue],
    span: (any SpanBase)?
  ) {
    span?.setAttribute(key: TCAAttributes.effectOutcome, value: outcome.rawValue)

    switch outcome {
    case .success:
      span?.status = .ok
      span?.addEvent(name: ComposableOTelSemantics.Events.effectCompleted)
      if policy.signals.metricsEnabled {
        var counter = metrics.effectsCompleted
        counter.add(value: 1, attributes: attributes)
      }
    case .cancelled:
      span?.status = .unset
      span?.setAttribute(key: TCAAttributes.effectCancelled, value: true)
      span?.addEvent(name: ComposableOTelSemantics.Events.effectCancelled)
      if policy.signals.metricsEnabled {
        var counter = metrics.effectsCancelled
        counter.add(value: 1, attributes: attributes)
      }
    case .error:
      break
    }
  }

  private func recordEffectError(
    _ error: any Error,
    effect: EffectID,
    attributes: [String: AttributeValue],
    span: (any SpanBase)?
  ) {
    let errorAttributes = telemetryErrorAttributes(for: error)
    span?.setAttribute(
      key: TCAAttributes.effectOutcome,
      value: TelemetryOutcome.error.rawValue
    )
    span?.status = .error(description: ComposableOTelSemantics.LogBodies.effectFailed)
    span?.addEvent(
      name: ComposableOTelSemantics.Events.exception,
      attributes: errorAttributes
    )

    if policy.signals.metricsEnabled {
      var counter = metrics.effectsErrored
      counter.add(value: 1, attributes: attributes)
    }

    emitLog(
      severity: .error,
      body: ComposableOTelSemantics.LogBodies.effectFailed,
      attributes: errorAttributes.merging([
        TCAAttributes.effectName: .string(effect.rawValue)
      ]) { _, new in new }
    )
  }

  func telemetryErrorAttributes(for error: any Error) -> [String: AttributeValue] {
    let metadata = policy.errorMetadata(for: error)
    var attributes: [String: AttributeValue] = [
      TCAAttributes.errorType: .string(metadata.type.rawValue),
      TCAAttributes.errorCategory: .string(metadata.category.rawValue),
      TCAAttributes.errorHandled: .bool(metadata.handled),
      TCAAttributes.errorRetryable: .bool(metadata.retryable),
    ]
    if let code = metadata.code {
      attributes[TCAAttributes.errorCode] = .string(code.rawValue)
    }
    return policy.sanitizedSpanAttributes(attributes)
  }
}
