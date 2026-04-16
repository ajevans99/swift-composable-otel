import Foundation
import OpenTelemetryApi

/// Manages TCA metric instruments.
///
/// Instruments are created lazily on first access from the global ``MeterProvider``.
public final class TCAMetrics: @unchecked Sendable {
  public static let shared = TCAMetrics()

  private let lock = NSLock()
  private var _meter: (any Meter)?

  /// Must be called with `lock` held.
  private func ensureMeter() -> any Meter {
    if let m = _meter { return m }
    let m = OpenTelemetry.instance.meterProvider.get(name: "ComposableOTel")
    _meter = m
    return m
  }

  // MARK: - Helper builders

  /// Must be called with `lock` held.
  private func buildCounter(_ name: String, storage: inout (any LongCounter)?) -> any LongCounter {
    if let c = storage { return c }
    let c = ensureMeter().counterBuilder(name: name).build()
    storage = c
    return c
  }

  /// Must be called with `lock` held.
  private func buildHistogram(
    _ name: String,
    storage: inout (any DoubleHistogram)?
  ) -> any DoubleHistogram {
    if let h = storage { return h }
    let h = ensureMeter().histogramBuilder(name: name).build()
    storage = h
    return h
  }

  /// Must be called with `lock` held.
  private func buildUpDownCounter(
    _ name: String,
    storage: inout (any LongUpDownCounter)?
  ) -> any LongUpDownCounter {
    if let c = storage { return c }
    let c = ensureMeter().upDownCounterBuilder(name: name).build()
    storage = c
    return c
  }

  // MARK: - Counters

  private var _actionsDispatched: (any LongCounter)?
  public var actionsDispatched: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    return buildCounter("tca.actions.dispatched", storage: &_actionsDispatched)
  }

  private var _effectsStarted: (any LongCounter)?
  public var effectsStarted: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    return buildCounter("tca.effects.started", storage: &_effectsStarted)
  }

  private var _effectsCompleted: (any LongCounter)?
  public var effectsCompleted: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    return buildCounter("tca.effects.completed", storage: &_effectsCompleted)
  }

  private var _effectsCancelled: (any LongCounter)?
  public var effectsCancelled: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    return buildCounter("tca.effects.cancelled", storage: &_effectsCancelled)
  }

  private var _effectsErrored: (any LongCounter)?
  public var effectsErrored: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    return buildCounter("tca.effects.errored", storage: &_effectsErrored)
  }

  private var _dependenciesCalled: (any LongCounter)?
  public var dependenciesCalled: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    return buildCounter("tca.dependencies.called", storage: &_dependenciesCalled)
  }

  private var _dependenciesErrored: (any LongCounter)?
  public var dependenciesErrored: any LongCounter {
    lock.lock(); defer { lock.unlock() }
    return buildCounter("tca.dependencies.errored", storage: &_dependenciesErrored)
  }

  // MARK: - Histograms

  private var _reducerDuration: (any DoubleHistogram)?
  public var reducerDuration: any DoubleHistogram {
    lock.lock(); defer { lock.unlock() }
    return buildHistogram("tca.reducer.duration", storage: &_reducerDuration)
  }

  private var _effectDuration: (any DoubleHistogram)?
  public var effectDuration: any DoubleHistogram {
    lock.lock(); defer { lock.unlock() }
    return buildHistogram("tca.effect.duration", storage: &_effectDuration)
  }

  private var _dependencyDuration: (any DoubleHistogram)?
  public var dependencyDuration: any DoubleHistogram {
    lock.lock(); defer { lock.unlock() }
    return buildHistogram("tca.dependency.duration", storage: &_dependencyDuration)
  }

  // MARK: - UpDownCounters

  private var _activeEffects: (any LongUpDownCounter)?
  public var activeEffects: any LongUpDownCounter {
    lock.lock(); defer { lock.unlock() }
    return buildUpDownCounter("tca.store.active_effects", storage: &_activeEffects)
  }
}
