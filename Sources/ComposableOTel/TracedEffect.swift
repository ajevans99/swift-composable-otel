import ComposableArchitecture
import Dependencies
import Foundation
import OpenTelemetryApi

private enum EffectTraceOutcome: String {
  case success
  case cancelled
  case error
}

// MARK: - Marker Modifier

extension Effect {
  /// Adds a start marker to an existing effect without observing its lifecycle.
  ///
  /// The marker captures an instrumented reducer span as its explicit parent when this method is
  /// called during reduction. Use ``tracedRun(name:priority:operation:)`` or
  /// ``tracedLongLivedRun(name:priority:operation:)`` for duration and outcome tracing.
  public func traceStart(name: String? = nil) -> Self {
    let effectName = name ?? "unnamed"
    let parentContext = ReducerTraceContext.spanContext
    let signalEffect: Self = .run { _ in
      @Dependency(\.composableOTel) var telemetry

      let spanBuilder = telemetry.tracer.spanBuilder(spanName: "effect/\(effectName)")
        .setSpanKind(spanKind: .internal)
        .setAttribute(key: TCAAttributes.effectName, value: effectName)
        .setAttribute(key: TCAAttributes.effectMarker, value: true)
      if let parentContext {
        spanBuilder.setParent(parentContext)
      } else {
        spanBuilder.setNoParent()
      }

      spanBuilder.withActiveSpan { span in
        span.status = .ok
        span.addEvent(name: "effect.started")
      }

      var counter = telemetry.metrics.effectsStarted
      counter.add(
        value: 1,
        attributes: [
          TCAAttributes.effectName: .string(effectName)
        ]
      )
    }
    return merge(with: signalEffect)
  }

  @available(*, deprecated, renamed: "traceStart(name:)")
  public func traced(name: String? = nil) -> Self {
    traceStart(name: name)
  }
}

// MARK: - Traced Effect Factories

extension Effect {
  /// Creates a one-shot `.run` effect with full OpenTelemetry lifecycle tracing.
  ///
  /// The effect captures an instrumented reducer span as its explicit parent when constructed
  /// during reduction. The operation runs with the effect span task-locally active, including
  /// across suspension and inherited child tasks. Errors and cancellation are recorded and then
  /// rethrown to TCA's normal `Effect.run` handling.
  public static func tracedRun(
    name: String,
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable (Send<Action>) async throws -> Void
  ) -> Self {
    tracedRun(name: name, priority: priority, longLived: false, operation: operation)
  }

  /// Creates a long-lived `.run` effect with full OpenTelemetry lifecycle tracing.
  ///
  /// Normal stream completion is recorded as success. Cancellation and errors are distinct
  /// outcomes and are rethrown to TCA's normal `Effect.run` handling.
  public static func tracedLongLivedRun(
    name: String,
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable (Send<Action>) async throws -> Void
  ) -> Self {
    tracedRun(name: name, priority: priority, longLived: true, operation: operation)
  }

  private static func tracedRun(
    name: String,
    priority: TaskPriority?,
    longLived: Bool,
    operation: @escaping @Sendable (Send<Action>) async throws -> Void
  ) -> Self {
    let parentContext = ReducerTraceContext.spanContext
    return .run(priority: priority, name: name) { send in
      @Dependency(\.composableOTel) var telemetry
      try await telemetry.withEffectTrace(
        name: name,
        longLived: longLived,
        parentContext: parentContext
      ) {
        try await operation(send)
      }
    }
  }
}

// MARK: - Structured Effect Lifecycle

extension TelemetryClient {
  func withEffectTrace<T: Sendable>(
    name: String,
    longLived: Bool,
    parentContext: SpanContext?,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let spanBuilder = tracer.spanBuilder(spanName: "effect/\(name)")
      .setSpanKind(spanKind: .internal)
      .setAttribute(key: TCAAttributes.effectName, value: name)
      .setAttribute(key: TCAAttributes.effectLongLived, value: longLived)
    if let parentContext {
      spanBuilder.setParent(parentContext)
    } else {
      spanBuilder.setNoParent()
    }

    let attributes: [String: AttributeValue] = [
      TCAAttributes.effectName: .string(name),
      TCAAttributes.effectLongLived: .bool(longLived),
    ]

    var startedCounter = metrics.effectsStarted
    startedCounter.add(value: 1, attributes: attributes)
    var activeCounter = metrics.activeEffects
    activeCounter.add(value: 1, attributes: attributes)

    let clock = ContinuousClock()
    let startTime = clock.now

    return try await spanBuilder.withActiveSpan { span in
      defer {
        var durationHistogram = metrics.effectDuration
        durationHistogram.record(
          value: durationMilliseconds(from: startTime, clock: clock),
          attributes: attributes
        )
        var activeCounter = metrics.activeEffects
        activeCounter.add(value: -1, attributes: attributes)
      }

      do {
        let result = try await operation()
        recordEffectOutcome(.success, name: name, attributes: attributes, span: span)
        return result
      } catch {
        if error is CancellationError {
          recordEffectOutcome(.cancelled, name: name, attributes: attributes, span: span)
        } else {
          recordEffectError(error, name: name, attributes: attributes, span: span)
        }
        throw error
      }
    }
  }

  private func recordEffectOutcome(
    _ outcome: EffectTraceOutcome,
    name: String,
    attributes: [String: AttributeValue],
    span: any SpanBase
  ) {
    span.setAttribute(key: TCAAttributes.effectOutcome, value: outcome.rawValue)

    switch outcome {
    case .success:
      span.status = .ok
      span.addEvent(name: "effect.completed")
      var completedCounter = metrics.effectsCompleted
      completedCounter.add(value: 1, attributes: attributes)
    case .cancelled:
      span.status = .unset
      span.setAttribute(key: TCAAttributes.effectCancelled, value: true)
      span.addEvent(name: "effect.cancelled")
      var cancelledCounter = metrics.effectsCancelled
      cancelledCounter.add(value: 1, attributes: attributes)
    case .error:
      break
    }
  }

  private func recordEffectError(
    _ error: any Error,
    name: String,
    attributes: [String: AttributeValue],
    span: any SpanBase
  ) {
    let body = errorDetailPolicy.errorBody(for: error, context: "Effect failed")
    let errorAttributes: [String: AttributeValue] = [
      TCAAttributes.errorType: .string(String(describing: type(of: error))),
      TCAAttributes.errorRedacted: .bool(errorDetailPolicy.isRedacted),
    ]

    span.setAttribute(key: TCAAttributes.effectOutcome, value: EffectTraceOutcome.error.rawValue)
    span.status = .error(description: body)
    span.addEvent(name: "exception", attributes: errorAttributes)

    var erroredCounter = metrics.effectsErrored
    erroredCounter.add(value: 1, attributes: attributes)

    var logAttributes = errorAttributes
    logAttributes[TCAAttributes.effectName] = .string(name)
    self.error(body, attributes: logAttributes)
  }
}

private func durationMilliseconds(from start: ContinuousClock.Instant, clock: ContinuousClock)
  -> Double
{
  let elapsed = clock.now - start
  return Double(elapsed.components.seconds) * 1000.0
    + Double(elapsed.components.attoseconds) / 1e15
}
