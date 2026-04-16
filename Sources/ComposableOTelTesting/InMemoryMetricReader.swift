import Foundation
import OpenTelemetrySdk

/// A metric reader that collects metric data in memory for test assertions.
///
/// Register this reader with a `MeterProviderBuilder` via
/// `registerMetricReader(reader:)`. Call ``collectMetrics()`` or
/// ``forceFlush()`` to trigger a collection pass and inspect ``metrics``.
public final class InMemoryMetricReader: MetricReader, @unchecked Sendable {
  private let lock = NSLock()
  private var _metrics: [MetricData] = []
  private var producer: MetricProducer?

  public init() {}

  /// All metric data collected so far.
  public var metrics: [MetricData] {
    lock.lock()
    defer { lock.unlock() }
    return _metrics
  }

  // MARK: - MetricReader

  public func register(registration: CollectionRegistration) {
    lock.lock()
    defer { lock.unlock() }
    producer = registration as? MetricProducer
  }

  public func forceFlush() -> ExportResult {
    collectMetrics()
    return .success
  }

  public func shutdown() -> ExportResult {
    lock.lock()
    defer { lock.unlock() }
    producer = nil
    return .success
  }

  // MARK: - AggregationTemporalitySelectorProtocol

  public func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality {
    .cumulative
  }

  // MARK: - DefaultAggregationSelector

  public func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation {
    Aggregations.defaultAggregation()
  }

  // MARK: - Test helpers

  /// Trigger a collection from the registered meter provider and store the results.
  @discardableResult
  public func collectMetrics() -> [MetricData] {
    lock.lock()
    let collected = producer?.collectAllMetrics() ?? []
    _metrics.append(contentsOf: collected)
    let result = _metrics
    lock.unlock()
    return result
  }

  /// Return only metrics whose name matches.
  public func metrics(named name: String) -> [MetricData] {
    metrics.filter { $0.name == name }
  }

  /// Remove all collected metrics.
  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    _metrics.removeAll()
  }
}
