import Dependencies
import Foundation
import OpenTelemetryApi

/// Traces a throwing dependency operation with typed, schema-bounded identifiers.
public func tracedCall<T: Sendable>(
  dependency: DependencyID,
  operation operationID: OperationID,
  operation: @Sendable () async throws -> T
) async throws -> T {
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
  @Dependency(\.composableOTel) var telemetry
  return await telemetry.withDependencyTrace(
    dependency: dependency,
    operation: operationID,
    operationBody: operation
  )
}

extension TelemetryClient {
  private func dependencyContext(
    dependency: DependencyID,
    operation: OperationID
  ) -> (DependencyID, OperationID, [String: AttributeValue]) {
    let dependency = policy.schema.bounded(dependency)
    let operation = policy.schema.bounded(operation)
    return (
      dependency,
      operation,
      [
        TCAAttributes.dependencyName: .string(dependency.rawValue),
        TCAAttributes.operationName: .string(operation.rawValue),
      ]
    )
  }

  fileprivate func withDependencyTrace<T: Sendable>(
    dependency: DependencyID,
    operation: OperationID,
    operationBody: @Sendable () async throws -> T
  ) async throws -> T {
    let (dependency, operation, attributes) = dependencyContext(
      dependency: dependency,
      operation: operation
    )
    let metricAttributes = policy.sanitizedMetricAttributes(
      attributes,
      instrumentName: ComposableOTelSemantics.Metrics.dependenciesCalled
    )
    if policy.signals.metricsEnabled {
      var calledCounter = metrics.dependenciesCalled
      calledCounter.add(value: 1, attributes: metricAttributes)
    }

    let clock = ContinuousClock()
    let startTime = clock.now
    if policy.signals.tracesEnabled {
      let spanBuilder =
        tracer
        .spanBuilder(spanName: ComposableOTelSemantics.Spans.dependency)
        .setSpanKind(spanKind: .internal)
        .setAttributes(policy.sanitizedSpanAttributes(attributes))
      return try await spanBuilder.withActiveSpan { span in
        try await runThrowingDependencyOperation(
          operationBody,
          dependency: dependency,
          operationID: operation,
          attributes: metricAttributes,
          startTime: startTime,
          clock: clock,
          span: span
        )
      }
    }

    return try await runThrowingDependencyOperation(
      operationBody,
      dependency: dependency,
      operationID: operation,
      attributes: metricAttributes,
      startTime: startTime,
      clock: clock,
      span: nil
    )
  }

  fileprivate func withDependencyTrace<T: Sendable>(
    dependency: DependencyID,
    operation: OperationID,
    operationBody: @Sendable () async -> T
  ) async -> T {
    let (_, _, attributes) = dependencyContext(
      dependency: dependency,
      operation: operation
    )
    let metricAttributes = policy.sanitizedMetricAttributes(
      attributes,
      instrumentName: ComposableOTelSemantics.Metrics.dependenciesCalled
    )
    if policy.signals.metricsEnabled {
      var calledCounter = metrics.dependenciesCalled
      calledCounter.add(value: 1, attributes: metricAttributes)
    }

    let clock = ContinuousClock()
    let startTime = clock.now
    if policy.signals.tracesEnabled {
      let spanBuilder =
        tracer
        .spanBuilder(spanName: ComposableOTelSemantics.Spans.dependency)
        .setSpanKind(spanKind: .internal)
        .setAttributes(policy.sanitizedSpanAttributes(attributes))
      return await spanBuilder.withActiveSpan { span in
        let result = await operationBody()
        span.status = .ok
        recordDependencyDuration(
          from: startTime,
          clock: clock,
          attributes: metricAttributes
        )
        return result
      }
    }

    let result = await operationBody()
    recordDependencyDuration(from: startTime, clock: clock, attributes: metricAttributes)
    return result
  }

  private func runThrowingDependencyOperation<T: Sendable>(
    _ operation: @Sendable () async throws -> T,
    dependency: DependencyID,
    operationID: OperationID,
    attributes: [String: AttributeValue],
    startTime: ContinuousClock.Instant,
    clock: ContinuousClock,
    span: (any SpanBase)?
  ) async throws -> T {
    defer {
      recordDependencyDuration(from: startTime, clock: clock, attributes: attributes)
    }
    do {
      let result = try await operation()
      span?.status = .ok
      return result
    } catch {
      let errorAttributes = telemetryErrorAttributes(for: error)
      span?.setAttribute(key: TCAAttributes.dependencyError, value: true)
      span?.status = .error(description: ComposableOTelSemantics.LogBodies.dependencyFailed)
      span?.addEvent(
        name: ComposableOTelSemantics.Events.exception,
        attributes: errorAttributes
      )

      if policy.signals.metricsEnabled {
        var erroredCounter = metrics.dependenciesErrored
        erroredCounter.add(value: 1, attributes: attributes)
      }
      emitLog(
        severity: .error,
        body: ComposableOTelSemantics.LogBodies.dependencyFailed,
        attributes: errorAttributes.merging([
          TCAAttributes.dependencyName: .string(dependency.rawValue),
          TCAAttributes.operationName: .string(operationID.rawValue),
        ]) { _, new in new }
      )
      throw error
    }
  }

  private func recordDependencyDuration(
    from startTime: ContinuousClock.Instant,
    clock: ContinuousClock,
    attributes: [String: AttributeValue]
  ) {
    guard policy.signals.metricsEnabled else { return }
    var histogram = metrics.dependencyDuration
    histogram.record(
      value: durationMilliseconds(from: startTime, clock: clock),
      attributes: attributes
    )
  }
}
