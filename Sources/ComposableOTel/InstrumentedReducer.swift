import ComposableArchitecture
import Dependencies
import Foundation
import OpenTelemetryApi

/// Options controlling what telemetry an instrumented reducer emits.
public struct InstrumentationOptions: Sendable {
  /// Compare pre/post `String(describing:)` snapshots for `tca.state.changed` (default: false).
  ///
  /// State contents and diffs are never emitted. When disabled, the current implementation
  /// records `tca.state.changed` as `true` without comparing state.
  public var stateDiffs: Bool

  /// Emit action dispatch log records (default: true).
  public var actionLogging: Bool

  /// Record metrics for reducer duration and action counts (default: true).
  public var metricsEnabled: Bool

  public init(
    stateDiffs: Bool = false,
    actionLogging: Bool = true,
    metricsEnabled: Bool = true
  ) {
    self.stateDiffs = stateDiffs
    self.actionLogging = actionLogging
    self.metricsEnabled = metricsEnabled
  }
}

/// A higher-order reducer that wraps another reducer with OpenTelemetry instrumentation.
///
/// Use the `.instrumented()` operator to apply this:
/// ```swift
/// Reduce { state, action in
///   // ...
/// }
/// .instrumented()
/// ```
public struct InstrumentedReducer<Base: Reducer>: Reducer {
  @usableFromInline let base: Base
  @usableFromInline let options: InstrumentationOptions
  @usableFromInline let reducerName: String

  @Dependency(\.composableOTel) var telemetry

  @inlinable
  public init(base: Base, name: String? = nil, options: InstrumentationOptions = .init()) {
    self.base = base
    self.options = options
    self.reducerName = name ?? Self.cleanReducerName(String(describing: Base.self))
  }

  public func _reduce(
    into state: inout Base.State,
    action: Base.Action
  ) -> Effect<Base.Action> {
    let actionName = Self.extractActionName(action)
    let spanName = "reducer/\(reducerName)"

    let span = telemetry.tracer.spanBuilder(spanName: spanName)
      .setSpanKind(spanKind: .internal)
      .setAttribute(key: TCAAttributes.reducerName, value: reducerName)
      .setAttribute(key: TCAAttributes.actionType, value: actionName)
      .setActive(true)
      .startSpan()

    let stateSnapshot: String? = options.stateDiffs ? String(describing: state) : nil

    let clock = ContinuousClock()
    let startTime = clock.now

    let effect = base._reduce(into: &state, action: action)

    let elapsed = clock.now - startTime
    let durationMs =
      Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000

    if let stateSnapshot {
      let newSnapshot = String(describing: state)
      span.setAttribute(key: TCAAttributes.stateChanged, value: newSnapshot != stateSnapshot)
    } else {
      span.setAttribute(key: TCAAttributes.stateChanged, value: true)
    }
    span.setAttribute(key: TCAAttributes.reducerDurationMs, value: durationMs)
    span.end()

    if options.metricsEnabled {
      let attrs: [String: AttributeValue] = [
        TCAAttributes.reducerName: .string(reducerName),
        TCAAttributes.actionType: .string(actionName),
      ]
      var actionsCounter = telemetry.metrics.actionsDispatched
      actionsCounter.add(value: 1, attributes: attrs)
      var durationHist = telemetry.metrics.reducerDuration
      durationHist.record(value: durationMs, attributes: attrs)
    }

    if options.actionLogging {
      telemetry.info(
        "Action dispatched: \(actionName)",
        attributes: [
          TCAAttributes.reducerName: .string(reducerName),
          TCAAttributes.actionType: .string(actionName),
          TCAAttributes.reducerDurationMs: .double(durationMs),
        ]
      )
    }

    return effect
  }

  // MARK: - Helpers

  @usableFromInline
  static func cleanReducerName(_ raw: String) -> String {
    var name = raw
    // Strip generic parameters like "InstrumentedReducer<Reduce<State, Action>>"
    if let angle = name.firstIndex(of: "<") {
      name = String(name[name.startIndex..<angle])
    }
    // Strip module prefix
    if let dot = name.lastIndex(of: ".") {
      name = String(name[name.index(after: dot)...])
    }
    return name
  }

  @usableFromInline
  static func extractActionName(_ action: Base.Action) -> String {
    let full = String(describing: action)
    // Take only the case name, stripping associated values: "goalRowTapped(123)" → "goalRowTapped"
    if let paren = full.firstIndex(of: "(") {
      return String(full[full.startIndex..<paren])
    }
    return full
  }
}

// MARK: - Reducer Extension

extension Reducer {
  /// Wraps this reducer with OpenTelemetry instrumentation.
  ///
  /// Each action produces a synchronous reducer span and, when enabled, action logs and metrics.
  /// Reducer effects are not covered by the reducer span.
  ///
  /// ```swift
  /// Reduce { state, action in
  ///   // ...
  /// }
  /// .instrumented()
  /// ```
  public func instrumented(
    name: String? = nil,
    options: InstrumentationOptions = .init()
  ) -> InstrumentedReducer<Self> {
    InstrumentedReducer(base: self, name: name, options: options)
  }
}
