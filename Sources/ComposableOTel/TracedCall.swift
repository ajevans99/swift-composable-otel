import Dependencies
import Foundation
import OpenTelemetryApi

/// Traces an async throwing dependency call with OpenTelemetry.
///
/// Creates a span `dependency/{dependencyName}/{method}` covering the call duration,
/// and records metrics for call count, duration, and errors.
///
/// When called from a TCA effect, inherits the store's dependency context automatically.
/// Outside TCA context, uses the live (global OTel) telemetry client.
///
/// ```swift
/// try await tracedCall("goalDatabase", method: "fetchGoal") {
///   try await self.fetchGoal(id)
/// }
/// ```
public func tracedCall<T: Sendable>(
  _ dependencyName: String,
  method: String,
  operation: @Sendable () async throws -> T
) async throws -> T {
  @Dependency(\.composableOTel) var telemetry

  let spanName = "dependency/\(dependencyName)/\(method)"
  let span = telemetry.tracer.spanBuilder(spanName: spanName)
    .setSpanKind(spanKind: .internal)
    .setAttribute(key: TCAAttributes.dependencyName, value: dependencyName)
    .setAttribute(key: TCAAttributes.dependencyMethod, value: method)
    .setActive(true)
    .startSpan()

  let attrs: [String: AttributeValue] = [
    TCAAttributes.dependencyName: .string(dependencyName),
    TCAAttributes.dependencyMethod: .string(method),
  ]

  var calledCounter = telemetry.metrics.dependenciesCalled
  calledCounter.add(value: 1, attributes: attrs)

  let clock = ContinuousClock()
  let startTime = clock.now

  do {
    let result = try await operation()

    let elapsed = clock.now - startTime
    let durationMs =
      Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000

    var durationHist = telemetry.metrics.dependencyDuration
    durationHist.record(value: durationMs, attributes: attrs)
    span.end()
    return result
  } catch {
    let elapsed = clock.now - startTime
    let durationMs =
      Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000

    let policy = telemetry.errorDetailPolicy
    let body = policy.errorBody(for: error, context: "Dependency call failed")

    span.setAttribute(key: TCAAttributes.dependencyError, value: true)
    span.status = .error(description: body)
    span.addEvent(
      name: "exception",
      attributes: [
        TCAAttributes.errorType: .string(String(describing: type(of: error))),
        TCAAttributes.errorRedacted: .bool(policy.isRedacted),
      ]
    )

    var erroredCounter = telemetry.metrics.dependenciesErrored
    erroredCounter.add(value: 1, attributes: attrs)
    var durationHist2 = telemetry.metrics.dependencyDuration
    durationHist2.record(value: durationMs, attributes: attrs)

    telemetry.error(
      body,
      attributes: [
        TCAAttributes.dependencyName: .string(dependencyName),
        TCAAttributes.dependencyMethod: .string(method),
        TCAAttributes.errorType: .string(String(describing: type(of: error))),
        TCAAttributes.errorRedacted: .bool(policy.isRedacted),
      ]
    )

    span.end()
    throw error
  }
}

/// Traces a non-throwing async dependency call with OpenTelemetry.
public func tracedCall<T: Sendable>(
  _ dependencyName: String,
  method: String,
  operation: @Sendable () async -> T
) async -> T {
  @Dependency(\.composableOTel) var telemetry

  let spanName = "dependency/\(dependencyName)/\(method)"
  let span = telemetry.tracer.spanBuilder(spanName: spanName)
    .setSpanKind(spanKind: .internal)
    .setAttribute(key: TCAAttributes.dependencyName, value: dependencyName)
    .setAttribute(key: TCAAttributes.dependencyMethod, value: method)
    .setActive(true)
    .startSpan()

  let attrs: [String: AttributeValue] = [
    TCAAttributes.dependencyName: .string(dependencyName),
    TCAAttributes.dependencyMethod: .string(method),
  ]

  var calledCounter = telemetry.metrics.dependenciesCalled
  calledCounter.add(value: 1, attributes: attrs)

  let clock = ContinuousClock()
  let startTime = clock.now

  let result = await operation()

  let elapsed = clock.now - startTime
  let durationMs =
    Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000

  var durationHist = telemetry.metrics.dependencyDuration
  durationHist.record(value: durationMs, attributes: attrs)
  span.end()
  return result
}
