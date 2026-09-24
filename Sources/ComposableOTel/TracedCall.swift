import Dependencies
import Foundation
import OpenTelemetryApi

/// Traces a throwing dependency operation with typed, schema-bounded identifiers.
///
/// Emits one `tca.dependency` span parented to the current reducer, effect, or root flow;
/// `tca.dependency.started` and `tca.dependency.completed` or `tca.dependency.failed` logs; and the
/// `tca.dependencies.called`, `tca.dependencies.errored`, and `tca.dependency.duration` metrics.
/// Cancellation reports outcome `cancelled` and is not counted as an error. Arguments, return values,
/// and error descriptions are never inspected.
public func tracedCall<T: Sendable>(
  dependency: DependencyID,
  operation operationID: OperationID,
  operation: @Sendable () async throws -> T
) async throws -> T {
  if ReducerTraceContext.instrumentationSuppressed {
    return try await operation()
  }
  @Dependency(\.composableOTel) var telemetry
  return try await telemetry.withDependencyTrace(
    dependency: dependency,
    operation: operationID,
    operationBody: operation
  )
}

/// Traces a nonthrowing dependency operation with typed, schema-bounded identifiers.
public func tracedCall<T: Sendable>(
  dependency: DependencyID,
  operation operationID: OperationID,
  operation: @Sendable () async -> T
) async -> T {
  if ReducerTraceContext.instrumentationSuppressed {
    return await operation()
  }
  @Dependency(\.composableOTel) var telemetry
  do {
    return try await telemetry.withDependencyTrace(
      dependency: dependency,
      operation: operationID,
      operationBody: { await operation() }
    )
  } catch {
    preconditionFailure("A nonthrowing dependency operation cannot throw")
  }
}

extension TelemetryClient {
  fileprivate func withDependencyTrace<T: Sendable>(
    dependency: DependencyID,
    operation: OperationID,
    operationBody: @Sendable () async throws -> T
  ) async throws -> T {
    let dependency = policy.schema.bounded(dependency)
    let operation = policy.schema.bounded(operation)
    let attributes: [String: AttributeValue] = [
      TCAAttributes.dependencyName: .string(dependency.rawValue),
      TCAAttributes.operationName: .string(operation.rawValue),
    ]
    let lifecycle = DependencyLifecycle(
      client: self,
      signalAttributes: ReducerTraceContext.addingFeature(to: attributes),
      metricAttributes: policy.sanitizedMetricAttributes(
        attributes,
        instrumentName: ComposableOTelSemantics.Metrics.dependenciesCalled
      )
    )
    if policy.signals.metricsEnabled {
      var calledCounter = metrics.dependenciesCalled
      calledCounter.add(value: 1, attributes: lifecycle.metricAttributes)
    }

    let clock = ContinuousClock()
    let startTime = clock.now
    if policy.signals.tracesEnabled {
      let spanBuilder =
        tracer
        .spanBuilder(spanName: ComposableOTelSemantics.Spans.dependency)
        .setSpanKind(spanKind: .internal)
        .setAttributes(policy.sanitizedSpanAttributes(lifecycle.signalAttributes))
      if let parentContext = ReducerTraceContext.spanContext {
        spanBuilder.setParent(parentContext)
      }
      return try await spanBuilder.withActiveSpan { span in
        try await ReducerTraceContext.$spanContext.withValue(span.context) {
          try await lifecycle.run(operationBody, startTime: startTime, clock: clock, span: span)
        }
      }
    }
    return try await lifecycle.run(operationBody, startTime: startTime, clock: clock, span: nil)
  }
}

private struct DependencyLifecycle: Sendable {
  let client: TelemetryClient
  let signalAttributes: [String: AttributeValue]
  let metricAttributes: [String: AttributeValue]

  private var policy: TelemetryPolicy { client.policy }

  func run<T: Sendable>(
    _ operation: @Sendable () async throws -> T,
    startTime: ContinuousClock.Instant,
    clock: ContinuousClock,
    span: (any SpanBase)?
  ) async throws -> T {
    client.emitLog(
      severity: .info,
      eventName: ComposableOTelSemantics.LogEvents.dependencyStarted,
      body: ComposableOTelSemantics.LogBodies.dependencyStarted,
      attributes: signalAttributes
    )
    do {
      let result = try await operation()
      let duration = recordDuration(from: startTime, clock: clock)
      recordCompleted(cancelled: false, duration: duration, span: span)
      return result
    } catch {
      let duration = recordDuration(from: startTime, clock: clock)
      if error is CancellationError {
        recordCompleted(cancelled: true, duration: duration, span: span)
      } else {
        recordFailed(error, duration: duration, span: span)
      }
      throw error
    }
  }

  private func recordDuration(
    from startTime: ContinuousClock.Instant,
    clock: ContinuousClock
  ) -> Double {
    let duration = durationMilliseconds(from: startTime, clock: clock)
    if policy.signals.metricsEnabled {
      var histogram = client.metrics.dependencyDuration
      histogram.record(value: duration, attributes: metricAttributes)
    }
    return duration
  }

  private func terminalAttributes(
    _ outcome: TelemetryOutcome,
    duration: Double
  ) -> [String: AttributeValue] {
    signalAttributes.merging([
      TCAAttributes.dependencyOutcome: .string(outcome.rawValue),
      TCAAttributes.dependencyDurationMs: .double(duration),
      TCAAttributes.dependencyCancelled: .bool(outcome == .cancelled),
    ]) { _, new in new }
  }

  private func recordCompleted(cancelled: Bool, duration: Double, span: (any SpanBase)?) {
    let outcome: TelemetryOutcome = cancelled ? .cancelled : .success
    span?.setAttribute(key: TCAAttributes.dependencyOutcome, value: outcome.rawValue)
    if cancelled {
      span?.setAttribute(key: TCAAttributes.dependencyCancelled, value: true)
      span?.status = .unset
    } else {
      span?.status = .ok
    }
    client.emitLog(
      severity: .info,
      eventName: ComposableOTelSemantics.LogEvents.dependencyCompleted,
      body: ComposableOTelSemantics.LogBodies.dependencyCompleted,
      attributes: terminalAttributes(outcome, duration: duration)
    )
  }

  private func recordFailed(_ error: any Error, duration: Double, span: (any SpanBase)?) {
    let errorAttributes = client.telemetryErrorAttributes(for: error)
    span?.setAttribute(key: TCAAttributes.dependencyError, value: true)
    span?.setAttribute(
      key: TCAAttributes.dependencyOutcome,
      value: TelemetryOutcome.error.rawValue
    )
    span?.status = .error(description: ComposableOTelSemantics.LogBodies.dependencyFailed)
    span?.addEvent(
      name: ComposableOTelSemantics.Events.exception,
      attributes: errorAttributes
    )
    if policy.signals.metricsEnabled {
      var erroredCounter = client.metrics.dependenciesErrored
      erroredCounter.add(value: 1, attributes: metricAttributes)
    }
    client.emitLog(
      severity: .error,
      eventName: ComposableOTelSemantics.LogEvents.dependencyFailed,
      body: ComposableOTelSemantics.LogBodies.dependencyFailed,
      attributes: terminalAttributes(.error, duration: duration).merging(errorAttributes) {
        _,
        new in new
      }
    )
  }
}
