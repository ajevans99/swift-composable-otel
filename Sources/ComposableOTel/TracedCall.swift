import Foundation
import OpenTelemetryApi

/// Traces an async throwing dependency call with OpenTelemetry.
///
/// Creates a span `dependency/{dependencyName}/{method}` covering the call duration,
/// and records metrics for call count, duration, and errors.
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
  let tracer = OpenTelemetry.instance.tracerProvider.get(
    instrumentationName: "ComposableOTel",
    instrumentationVersion: "0.1.0"
  )

  let spanName = "dependency/\(dependencyName)/\(method)"
  let span = tracer.spanBuilder(spanName: spanName)
    .setSpanKind(spanKind: .internal)
    .setAttribute(key: TCAAttributes.dependencyName, value: dependencyName)
    .setAttribute(key: TCAAttributes.dependencyMethod, value: method)
    .setActive(true)
    .startSpan()

  let attrs: [String: AttributeValue] = [
    TCAAttributes.dependencyName: .string(dependencyName),
    TCAAttributes.dependencyMethod: .string(method),
  ]

  var calledCounter = TCAMetrics.shared.dependenciesCalled
  calledCounter.add(value: 1, attributes: attrs)

  let clock = ContinuousClock()
  let startTime = clock.now

  do {
    let result = try await operation()

    let elapsed = clock.now - startTime
    let durationMs = Double(elapsed.components.attoseconds) / 1e15 +
      Double(elapsed.components.seconds) * 1000

    var durationHist = TCAMetrics.shared.dependencyDuration
    durationHist.record(value: durationMs, attributes: attrs)
    span.end()
    return result
  } catch {
    let elapsed = clock.now - startTime
    let durationMs = Double(elapsed.components.attoseconds) / 1e15 +
      Double(elapsed.components.seconds) * 1000

    let policy = TelemetryConfiguration.shared.errorDetailPolicy
    let body = policy.errorBody(for: error, context: "Dependency call failed")

    span.setAttribute(key: TCAAttributes.dependencyError, value: true)
    span.status = .error(description: body)
    span.addEvent(name: "exception", attributes: [
      TCAAttributes.errorType: .string(String(describing: type(of: error))),
      TCAAttributes.errorRedacted: .bool(policy.isRedacted),
    ])

    var erroredCounter = TCAMetrics.shared.dependenciesErrored
    erroredCounter.add(value: 1, attributes: attrs)
    var durationHist2 = TCAMetrics.shared.dependencyDuration
    durationHist2.record(value: durationMs, attributes: attrs)

    TCALogger.shared.error(body, attributes: [
      TCAAttributes.dependencyName: .string(dependencyName),
      TCAAttributes.dependencyMethod: .string(method),
      TCAAttributes.errorType: .string(String(describing: type(of: error))),
      TCAAttributes.errorRedacted: .bool(policy.isRedacted),
    ])

    span.end()
    throw error
  }
}

/// Traces a non-throwing async dependency call with OpenTelemetry.
///
/// ```swift
/// await tracedCall("myClient", method: "loadCache") {
///   await self.loadCache()
/// }
/// ```
public func tracedCall<T: Sendable>(
  _ dependencyName: String,
  method: String,
  operation: @Sendable () async -> T
) async -> T {
  let tracer = OpenTelemetry.instance.tracerProvider.get(
    instrumentationName: "ComposableOTel",
    instrumentationVersion: "0.1.0"
  )

  let spanName = "dependency/\(dependencyName)/\(method)"
  let span = tracer.spanBuilder(spanName: spanName)
    .setSpanKind(spanKind: .internal)
    .setAttribute(key: TCAAttributes.dependencyName, value: dependencyName)
    .setAttribute(key: TCAAttributes.dependencyMethod, value: method)
    .setActive(true)
    .startSpan()

  let attrs: [String: AttributeValue] = [
    TCAAttributes.dependencyName: .string(dependencyName),
    TCAAttributes.dependencyMethod: .string(method),
  ]

  var calledCounter = TCAMetrics.shared.dependenciesCalled
  calledCounter.add(value: 1, attributes: attrs)

  let clock = ContinuousClock()
  let startTime = clock.now

  let result = await operation()

  let elapsed = clock.now - startTime
  let durationMs = Double(elapsed.components.attoseconds) / 1e15 +
    Double(elapsed.components.seconds) * 1000

  var durationHist = TCAMetrics.shared.dependencyDuration
  durationHist.record(value: durationMs, attributes: attrs)
  span.end()
  return result
}
