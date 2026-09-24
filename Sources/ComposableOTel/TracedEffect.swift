import Dependencies
import Foundation
import OpenTelemetryApi

#if canImport(ComposableArchitecture)
  import ComposableArchitecture

  extension Effect {
    /// Adds a bounded initiation marker without observing the effect lifecycle.
    public func traceStart(effect: EffectID) -> Self {
      let traceContext = ReducerTraceContext.capture()
      guard !traceContext.instrumentationSuppressed else { return self }
      let signalEffect: Self = .run { _ in
        @Dependency(\.composableOTel) var telemetry

        let effect = telemetry.policy.schema.bounded(effect)
        let attributes: [String: AttributeValue] = [
          TCAAttributes.effectName: .string(effect.rawValue),
          TCAAttributes.effectLongLived: .bool(false),
          TCAAttributes.effectMarker: .bool(true),
        ]
        let signalAttributes = ReducerTraceContext.addingFeature(
          to: attributes,
          feature: traceContext.feature
        )

        var markerContext = traceContext.spanContext
        if telemetry.policy.signals.tracesEnabled {
          let spanBuilder = telemetry.tracer
            .spanBuilder(spanName: ComposableOTelSemantics.Spans.effect)
            .setSpanKind(spanKind: .internal)
            .setAttributes(telemetry.policy.sanitizedSpanAttributes(signalAttributes))
          if let parentContext = traceContext.spanContext {
            spanBuilder.setParent(parentContext)
          } else {
            spanBuilder.setNoParent()
          }
          markerContext = spanBuilder.withActiveSpan { span in
            span.status = .ok
            span.addEvent(name: ComposableOTelSemantics.Events.effectStarted)
            return span.context
          }
        }

        await traceContext.withValues {
          telemetry.emitLog(
            severity: .info,
            eventName: ComposableOTelSemantics.LogEvents.effectStarted,
            body: ComposableOTelSemantics.LogBodies.effectStarted,
            attributes: signalAttributes,
            spanContext: markerContext
          )
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

    /// Creates a one-shot effect that deliberately starts a new root trace.
    ///
    /// Use this for work that must not be attributed to the dispatching reducer action, such as a
    /// background refresh kicked off by an app lifecycle action. The effect span has no parent,
    /// carries `tca.flow.root = true`, and becomes the parent of nested dependency calls.
    public static func tracedRootRun(
      feature: FeatureID,
      effect: EffectID,
      priority: TaskPriority? = nil,
      operation: @escaping @Sendable (Send<Action>) async throws -> Void
    ) -> Self {
      let traceContext = ReducerTraceContext.capture()
      return .run(priority: priority, name: effect.rawValue) { send in
        try await traceContext.withValues {
          if traceContext.instrumentationSuppressed {
            return try await operation(send)
          }
          @Dependency(\.composableOTel) var telemetry
          return try await telemetry.withEffectTrace(
            effect: effect,
            longLived: false,
            parentContext: nil,
            feature: telemetry.policy.schema.bounded(feature),
            root: true
          ) {
            try await operation(send)
          }
        }
      }
    }

    private static func tracedRun(
      effect: EffectID,
      priority: TaskPriority?,
      longLived: Bool,
      operation: @escaping @Sendable (Send<Action>) async throws -> Void
    ) -> Self {
      let traceContext = ReducerTraceContext.capture()
      return .run(priority: priority, name: effect.rawValue) { send in
        try await traceContext.withValues {
          if traceContext.instrumentationSuppressed {
            return try await operation(send)
          }
          @Dependency(\.composableOTel) var telemetry
          return try await telemetry.withEffectTrace(
            effect: effect,
            longLived: longLived,
            parentContext: traceContext.spanContext,
            feature: traceContext.feature
          ) {
            try await operation(send)
          }
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
    feature: FeatureID? = ReducerTraceContext.feature,
    root: Bool = false,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    guard !ReducerTraceContext.instrumentationSuppressed else {
      return try await operation()
    }
    let effect = policy.schema.bounded(effect)
    let attributes: [String: AttributeValue] = [
      TCAAttributes.effectName: .string(effect.rawValue),
      TCAAttributes.effectLongLived: .bool(longLived),
    ]
    let metricAttributes = policy.sanitizedMetricAttributes(
      attributes,
      instrumentName: ComposableOTelSemantics.Metrics.effectsStarted
    )
    var signalAttributes = ReducerTraceContext.addingFeature(to: attributes, feature: feature)
    if root {
      signalAttributes[TCAAttributes.flowRoot] = .bool(true)
    }
    let lifecycle = EffectLifecycle(
      client: self,
      signalAttributes: signalAttributes,
      metricAttributes: metricAttributes
    )

    if policy.signals.metricsEnabled {
      var startedCounter = metrics.effectsStarted
      startedCounter.add(value: 1, attributes: metricAttributes)
      var activeCounter = metrics.activeEffects
      activeCounter.add(value: 1, attributes: metricAttributes)
    }

    let clock = ContinuousClock()
    let startTime = clock.now

    return try await ReducerTraceContext.$feature.withValue(feature) {
      if policy.signals.tracesEnabled {
        let spanBuilder =
          tracer
          .spanBuilder(spanName: ComposableOTelSemantics.Spans.effect)
          .setSpanKind(spanKind: .internal)
          .setAttributes(policy.sanitizedSpanAttributes(signalAttributes))
        if let parentContext {
          spanBuilder.setParent(parentContext)
        } else {
          spanBuilder.setNoParent()
        }
        return try await spanBuilder.withActiveSpan { span in
          try await ReducerTraceContext.$spanContext.withValue(span.context) {
            try await lifecycle.run(
              operation,
              startTime: startTime,
              clock: clock,
              span: span
            )
          }
        }
      }

      return try await lifecycle.run(
        operation,
        startTime: startTime,
        clock: clock,
        span: nil
      )
    }
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

private struct EffectLifecycle: Sendable {
  let client: TelemetryClient
  let signalAttributes: [String: AttributeValue]
  let metricAttributes: [String: AttributeValue]

  private var policy: TelemetryPolicy { client.policy }
  private var metrics: MetricInstruments { client.metrics }

  func run<T: Sendable>(
    _ operation: @Sendable () async throws -> T,
    startTime: ContinuousClock.Instant,
    clock: ContinuousClock,
    span: (any SpanBase)?
  ) async throws -> T {
    client.emitLog(
      severity: .info,
      eventName: ComposableOTelSemantics.LogEvents.effectStarted,
      body: ComposableOTelSemantics.LogBodies.effectStarted,
      attributes: signalAttributes
    )

    do {
      let result = try await operation()
      let duration = durationMilliseconds(from: startTime, clock: clock)
      recordDuration(duration)
      recordCompleted(duration: duration, span: span)
      return result
    } catch {
      let duration = durationMilliseconds(from: startTime, clock: clock)
      recordDuration(duration)
      if error is CancellationError {
        recordCancelled(duration: duration, span: span)
      } else {
        recordFailed(error, duration: duration, span: span)
      }
      throw error
    }
  }

  private func recordDuration(_ duration: Double) {
    guard policy.signals.metricsEnabled else { return }
    var durationHistogram = metrics.effectDuration
    durationHistogram.record(value: duration, attributes: metricAttributes)
    var activeCounter = metrics.activeEffects
    activeCounter.add(value: -1, attributes: metricAttributes)
  }

  private func terminalAttributes(
    _ outcome: TelemetryOutcome,
    duration: Double
  ) -> [String: AttributeValue] {
    signalAttributes.merging([
      TCAAttributes.effectOutcome: .string(outcome.rawValue),
      TCAAttributes.effectDurationMs: .double(duration),
      TCAAttributes.effectCancelled: .bool(outcome == .cancelled),
    ]) { _, new in new }
  }

  private func recordCompleted(duration: Double, span: (any SpanBase)?) {
    span?.setAttribute(key: TCAAttributes.effectOutcome, value: TelemetryOutcome.success.rawValue)
    span?.status = .ok
    span?.addEvent(name: ComposableOTelSemantics.Events.effectCompleted)
    if policy.signals.metricsEnabled {
      var counter = metrics.effectsCompleted
      counter.add(value: 1, attributes: metricAttributes)
    }
    client.emitLog(
      severity: .info,
      eventName: ComposableOTelSemantics.LogEvents.effectCompleted,
      body: ComposableOTelSemantics.LogBodies.effectCompleted,
      attributes: terminalAttributes(.success, duration: duration)
    )
  }

  private func recordCancelled(duration: Double, span: (any SpanBase)?) {
    span?.setAttribute(
      key: TCAAttributes.effectOutcome,
      value: TelemetryOutcome.cancelled.rawValue
    )
    span?.status = .unset
    span?.setAttribute(key: TCAAttributes.effectCancelled, value: true)
    span?.addEvent(name: ComposableOTelSemantics.Events.effectCancelled)
    if policy.signals.metricsEnabled {
      var counter = metrics.effectsCancelled
      counter.add(value: 1, attributes: metricAttributes)
    }
    client.emitLog(
      severity: .info,
      eventName: ComposableOTelSemantics.LogEvents.effectCancelled,
      body: ComposableOTelSemantics.LogBodies.effectCancelled,
      attributes: terminalAttributes(.cancelled, duration: duration)
    )
  }

  private func recordFailed(_ error: any Error, duration: Double, span: (any SpanBase)?) {
    let errorAttributes = client.telemetryErrorAttributes(for: error)
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
      counter.add(value: 1, attributes: metricAttributes)
    }
    client.emitLog(
      severity: .error,
      eventName: ComposableOTelSemantics.LogEvents.effectFailed,
      body: ComposableOTelSemantics.LogBodies.effectFailed,
      attributes: terminalAttributes(.error, duration: duration).merging(errorAttributes) {
        _,
        new in new
      }
    )
  }
}
