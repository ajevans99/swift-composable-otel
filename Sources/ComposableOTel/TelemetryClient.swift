import Dependencies
import DependenciesMacros
import Foundation
import OpenTelemetryApi

/// A stable reference cache for OTel metric instruments.
///
/// Instruments are created lazily from a `Meter` and shared across all copies
/// of `TelemetryClient`. This avoids re-creating instruments on each dependency
/// value copy.
public final class MetricInstruments: @unchecked Sendable {
  private let lock = NSLock()
  private let meter: any Meter

  public init(meter: any Meter) {
    self.meter = meter
  }

  // MARK: - Counters

  private var _actionsDispatched: (any LongCounter)?
  public var actionsDispatched: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    if let c = _actionsDispatched { return c }
    let c = meter.counterBuilder(name: "tca.actions.dispatched").build()
    _actionsDispatched = c
    return c
  }

  private var _effectsStarted: (any LongCounter)?
  public var effectsStarted: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    if let c = _effectsStarted { return c }
    let c = meter.counterBuilder(name: "tca.effects.started").build()
    _effectsStarted = c
    return c
  }

  private var _effectsCompleted: (any LongCounter)?
  public var effectsCompleted: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    if let c = _effectsCompleted { return c }
    let c = meter.counterBuilder(name: "tca.effects.completed").build()
    _effectsCompleted = c
    return c
  }

  private var _effectsCancelled: (any LongCounter)?
  public var effectsCancelled: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    if let c = _effectsCancelled { return c }
    let c = meter.counterBuilder(name: "tca.effects.cancelled").build()
    _effectsCancelled = c
    return c
  }

  private var _effectsErrored: (any LongCounter)?
  public var effectsErrored: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    if let c = _effectsErrored { return c }
    let c = meter.counterBuilder(name: "tca.effects.errored").build()
    _effectsErrored = c
    return c
  }

  private var _dependenciesCalled: (any LongCounter)?
  public var dependenciesCalled: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    if let c = _dependenciesCalled { return c }
    let c = meter.counterBuilder(name: "tca.dependencies.called").build()
    _dependenciesCalled = c
    return c
  }

  private var _dependenciesErrored: (any LongCounter)?
  public var dependenciesErrored: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    if let c = _dependenciesErrored { return c }
    let c = meter.counterBuilder(name: "tca.dependencies.errored").build()
    _dependenciesErrored = c
    return c
  }

  // MARK: - Histograms

  private var _reducerDuration: (any DoubleHistogram)?
  public var reducerDuration: any DoubleHistogram {
    lock.lock(); defer { lock.unlock() }
    if let h = _reducerDuration { return h }
    let h = meter.histogramBuilder(name: "tca.reducer.duration").build()
    _reducerDuration = h
    return h
  }

  private var _effectDuration: (any DoubleHistogram)?
  public var effectDuration: any DoubleHistogram {
    lock.lock(); defer { lock.unlock() }
    if let h = _effectDuration { return h }
    let h = meter.histogramBuilder(name: "tca.effect.duration").build()
    _effectDuration = h
    return h
  }

  private var _dependencyDuration: (any DoubleHistogram)?
  public var dependencyDuration: any DoubleHistogram {
    lock.lock(); defer { lock.unlock() }
    if let h = _dependencyDuration { return h }
    let h = meter.histogramBuilder(name: "tca.dependency.duration").build()
    _dependencyDuration = h
    return h
  }

  // MARK: - UpDownCounters

  private var _activeEffects: (any LongUpDownCounter)?
  public var activeEffects: any LongUpDownCounter {
    lock.lock(); defer { lock.unlock() }
    if let c = _activeEffects { return c }
    let c = meter.upDownCounterBuilder(name: "tca.store.active_effects").build()
    _activeEffects = c
    return c
  }
}

/// A Sendable wrapper around `any Tracer`, since the OTel `Tracer` protocol
/// does not (yet) conform to `Sendable`. The concrete implementations
/// (`TracerSdk`, `DefaultTracer`) are de facto thread-safe.
public struct SendableTracer: @unchecked Sendable {
  public let underlying: any Tracer

  public init(_ tracer: any Tracer) {
    self.underlying = tracer
  }

  public func spanBuilder(spanName: String) -> SpanBuilder {
    underlying.spanBuilder(spanName: spanName)
  }
}

/// The runtime client for TCA OpenTelemetry instrumentation.
///
/// Access via `@Dependency(\.composableOTel)`. Holds references to the OTel tracer,
/// metric instruments, and error handling configuration.
///
/// The `liveValue` reads from `OpenTelemetry.instance` globals. Override in tests:
/// ```swift
/// let store = TestStore(...) {
///   MyFeature()
/// } withDependencies: {
///   $0.composableOTel = .test(spanCollector: collector)
/// }
/// ```
public struct TelemetryClient: Sendable {
  /// The OTel tracer for creating spans.
  public var tracer: SendableTracer

  /// Pre-built metric instruments (reference-stable cache).
  public var metrics: MetricInstruments

  /// How error details are exported in telemetry.
  public var errorDetailPolicy: ErrorDetailPolicy

  /// Attribute redactor applied before export.
  public var redactor: any SpanAttributeRedactor

  public init(
    tracer: any Tracer,
    metrics: MetricInstruments,
    errorDetailPolicy: ErrorDetailPolicy = .redacted,
    redactor: any SpanAttributeRedactor = NoOpRedactor()
  ) {
    self.tracer = SendableTracer(tracer)
    self.metrics = metrics
    self.errorDetailPolicy = errorDetailPolicy
    self.redactor = redactor
  }
}

// MARK: - Logger helper

extension TelemetryClient {
  /// Emit a structured log record.
  public func log(severity: Severity, body: String, attributes: [String: AttributeValue] = [:]) {
    let logger = OpenTelemetry.instance.loggerProvider
      .loggerBuilder(instrumentationScopeName: "ComposableOTel")
      .setInstrumentationVersion("0.1.0")
      .build()
    logger.logRecordBuilder()
      .setSeverity(severity)
      .setBody(.string(body))
      .setAttributes(attributes)
      .emit()
  }

  public func error(_ body: String, attributes: [String: AttributeValue] = [:]) {
    log(severity: .error, body: body, attributes: attributes)
  }

  public func info(_ body: String, attributes: [String: AttributeValue] = [:]) {
    log(severity: .info, body: body, attributes: attributes)
  }
}

// MARK: - DependencyKey

private enum TelemetryClientKey: DependencyKey {
  static let liveValue: TelemetryClient = {
    let tracer = OpenTelemetry.instance.tracerProvider.get(
      instrumentationName: "ComposableOTel",
      instrumentationVersion: "0.1.0"
    )
    let meter = OpenTelemetry.instance.meterProvider.get(name: "ComposableOTel")
    return TelemetryClient(
      tracer: tracer,
      metrics: MetricInstruments(meter: meter)
    )
  }()

  static let testValue: TelemetryClient = {
    // Default test value uses no-op providers (DefaultTracer, DefaultMeter)
    let tracer = DefaultTracerProvider.instance.get(
      instrumentationName: "ComposableOTel",
      instrumentationVersion: "0.1.0"
    )
    let meter = DefaultMeterProvider.instance.get(name: "ComposableOTel")
    return TelemetryClient(
      tracer: tracer,
      metrics: MetricInstruments(meter: meter)
    )
  }()
}

extension DependencyValues {
  /// The TCA OpenTelemetry instrumentation client.
  ///
  /// Override in tests:
  /// ```swift
  /// $0.composableOTel = .test(spanCollector: collector)
  /// ```
  public var composableOTel: TelemetryClient {
    get { self[TelemetryClientKey.self] }
    set { self[TelemetryClientKey.self] = newValue }
  }
}
