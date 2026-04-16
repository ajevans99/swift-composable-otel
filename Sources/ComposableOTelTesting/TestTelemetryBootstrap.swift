import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// The collectors returned by ``configureTestTelemetry(spanCollector:metricReader:)``.
public struct TestTelemetry: Sendable {
  public let spanCollector: InMemorySpanCollector
  public let metricReader: InMemoryMetricReader?
}

/// Configure the global OpenTelemetry providers for testing with in-memory
/// collectors.
///
/// Call this at the start of each test (or in `setUp`). The returned
/// ``TestTelemetry`` gives you access to the collectors for assertions.
///
/// - Parameters:
///   - spanCollector: An ``InMemorySpanCollector`` to receive exported spans.
///     A new one is created if not provided.
///   - metricReader: An optional ``InMemoryMetricReader``. When provided, a
///     `MeterProviderSdk` is built and registered with this reader.
/// - Returns: A ``TestTelemetry`` holding the collectors.
@discardableResult
public func configureTestTelemetry(
  spanCollector: InMemorySpanCollector = InMemorySpanCollector(),
  metricReader: InMemoryMetricReader? = nil
) -> TestTelemetry {
  // Traces
  let processor = SimpleSpanProcessor(spanExporter: spanCollector)
  let tracerProvider = TracerProviderBuilder()
    .add(spanProcessor: processor)
    .build()
  OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

  // Metrics (optional)
  if let metricReader {
    let meterProvider = MeterProviderSdk.builder()
      .registerMetricReader(reader: metricReader)
      .build()
    OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)
  }

  return TestTelemetry(
    spanCollector: spanCollector,
    metricReader: metricReader
  )
}
