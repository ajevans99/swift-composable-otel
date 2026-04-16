import ComposableArchitecture
import Dependencies
import Foundation
import OpenTelemetryApi

// MARK: - Traced Effect Modifier

extension Effect {
  /// Adds a lightweight tracing signal to an existing effect.
  ///
  /// Because `Effect` internals are opaque, this modifier merges a signal effect
  /// that records a span marking the effect was initiated. For full lifecycle tracing
  /// (duration, error recording, cancellation), use ``tracedRun(name:priority:operation:)``
  /// instead.
  public func traced(name: String? = nil) -> Self {
    let effectName = name ?? "unnamed"
    let signalEffect: Self = .run { _ in
      @Dependency(\.composableOTel) var telemetry
      let span = telemetry.tracer.spanBuilder(spanName: "effect/\(effectName)")
        .setSpanKind(spanKind: .internal)
        .setAttribute(key: TCAAttributes.effectName, value: effectName)
        .setActive(true)
        .startSpan()
      span.end()

      var counter = telemetry.metrics.effectsStarted
      counter.add(value: 1, attributes: [
        TCAAttributes.effectName: .string(effectName),
      ])
    }
    return self.merge(with: signalEffect)
  }
}

// MARK: - Factory for Traced Effects

extension Effect {
  /// Creates a new traced `.run` effect with full OpenTelemetry lifecycle tracing.
  ///
  /// This is the preferred way to create traced effects. The operation is wrapped directly,
  /// providing accurate duration measurement, cancellation detection, and error recording.
  ///
  /// ```swift
  /// return .tracedRun(name: "fetchGoals") { send in
  ///   let goals = try await database.fetchAllGoals()
  ///   await send(.goalsLoaded(goals))
  /// }
  /// ```
  public static func tracedRun(
    name: String,
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable (Send<Action>) async throws -> Void
  ) -> Self {
    .run(priority: priority) { send in
      @Dependency(\.composableOTel) var telemetry

      let span = telemetry.tracer.spanBuilder(spanName: "effect/\(name)")
        .setSpanKind(spanKind: .internal)
        .setAttribute(key: TCAAttributes.effectName, value: name)
        .setAttribute(key: TCAAttributes.effectLongLived, value: false)
        .setActive(true)
        .startSpan()

      var startedCounter = telemetry.metrics.effectsStarted
      startedCounter.add(value: 1, attributes: [
        TCAAttributes.effectName: .string(name),
      ])
      var activeUp = telemetry.metrics.activeEffects
      activeUp.add(value: 1, attributes: [:])

      let clock = ContinuousClock()
      let startTime = clock.now

      do {
        try await operation(send)

        let durationMs = durationMilliseconds(from: startTime, clock: clock)
        span.end()

        var completedCounter = telemetry.metrics.effectsCompleted
        completedCounter.add(value: 1, attributes: [
          TCAAttributes.effectName: .string(name),
        ])
        var durationHist = telemetry.metrics.effectDuration
        durationHist.record(value: durationMs, attributes: [
          TCAAttributes.effectName: .string(name),
        ])
        var activeDown = telemetry.metrics.activeEffects
        activeDown.add(value: -1, attributes: [:])
      } catch is CancellationError {
        let durationMs = durationMilliseconds(from: startTime, clock: clock)
        span.addEvent(name: "effect.cancelled")
        span.setAttribute(key: TCAAttributes.effectCancelled, value: true)
        span.end()

        var cancelledCounter = telemetry.metrics.effectsCancelled
        cancelledCounter.add(value: 1, attributes: [
          TCAAttributes.effectName: .string(name),
        ])
        var durationHist = telemetry.metrics.effectDuration
        durationHist.record(value: durationMs, attributes: [
          TCAAttributes.effectName: .string(name),
        ])
        var activeDown = telemetry.metrics.activeEffects
        activeDown.add(value: -1, attributes: [:])
      } catch {
        let durationMs = durationMilliseconds(from: startTime, clock: clock)
        let policy = telemetry.errorDetailPolicy
        let body = policy.errorBody(for: error, context: "Effect failed")

        span.status = .error(description: body)
        span.addEvent(name: "exception", attributes: [
          TCAAttributes.errorType: .string(String(describing: type(of: error))),
          TCAAttributes.errorRedacted: .bool(policy.isRedacted),
        ])
        span.end()

        var erroredCounter = telemetry.metrics.effectsErrored
        erroredCounter.add(value: 1, attributes: [
          TCAAttributes.effectName: .string(name),
        ])
        var durationHist = telemetry.metrics.effectDuration
        durationHist.record(value: durationMs, attributes: [
          TCAAttributes.effectName: .string(name),
        ])
        var activeDown = telemetry.metrics.activeEffects
        activeDown.add(value: -1, attributes: [:])

        telemetry.error(body, attributes: [
          TCAAttributes.effectName: .string(name),
          TCAAttributes.errorType: .string(String(describing: type(of: error))),
          TCAAttributes.errorRedacted: .bool(policy.isRedacted),
        ])
      }
    }
  }

  /// Creates a traced long-lived effect with start/end marker spans.
  ///
  /// Use for effects that run indefinitely (e.g., listeners, streams).
  public static func tracedLongLivedRun(
    name: String,
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable (Send<Action>) async throws -> Void
  ) -> Self {
    .run(priority: priority) { send in
      @Dependency(\.composableOTel) var telemetry

      let startSpan = telemetry.tracer.spanBuilder(spanName: "effect/\(name)/start")
        .setSpanKind(spanKind: .internal)
        .setAttribute(key: TCAAttributes.effectName, value: name)
        .setAttribute(key: TCAAttributes.effectLongLived, value: true)
        .startSpan()
      startSpan.end()

      var startedCounter = telemetry.metrics.effectsStarted
      startedCounter.add(value: 1, attributes: [
        TCAAttributes.effectName: .string(name),
      ])
      var activeUp = telemetry.metrics.activeEffects
      activeUp.add(value: 1, attributes: [:])

      let clock = ContinuousClock()
      let startTime = clock.now

      do {
        try await operation(send)
      } catch is CancellationError {
        // Expected for long-lived effects
      } catch {
        let policy = telemetry.errorDetailPolicy
        let body = policy.errorBody(for: error, context: "Long-lived effect failed")
        telemetry.error(body, attributes: [
          TCAAttributes.effectName: .string(name),
          TCAAttributes.errorType: .string(String(describing: type(of: error))),
          TCAAttributes.errorRedacted: .bool(policy.isRedacted),
        ])
      }

      let durationMs = durationMilliseconds(from: startTime, clock: clock)

      let endSpan = telemetry.tracer.spanBuilder(spanName: "effect/\(name)/end")
        .setSpanKind(spanKind: .internal)
        .setAttribute(key: TCAAttributes.effectName, value: name)
        .setAttribute(key: TCAAttributes.effectLongLived, value: true)
        .startSpan()
      endSpan.end()

      var completedCounter = telemetry.metrics.effectsCompleted
      completedCounter.add(value: 1, attributes: [
        TCAAttributes.effectName: .string(name),
      ])
      var durationHist = telemetry.metrics.effectDuration
      durationHist.record(value: durationMs, attributes: [
        TCAAttributes.effectName: .string(name),
      ])
      var activeDown = telemetry.metrics.activeEffects
      activeDown.add(value: -1, attributes: [:])
    }
  }
}

// MARK: - Duration Helper

private func durationMilliseconds(from start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
  let elapsed = clock.now - start
  return Double(elapsed.components.seconds) * 1000.0
    + Double(elapsed.components.attoseconds) / 1e15
}
