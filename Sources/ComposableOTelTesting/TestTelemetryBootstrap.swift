import ComposableOTel
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Convenience factory for creating a ``TelemetryClient`` wired to in-memory
/// collectors, suitable for test assertions.
///
/// ```swift
/// let (client, collector) = TelemetryClient.test()
/// let store = TestStore(...) {
///   MyFeature()
/// } withDependencies: {
///   $0.composableOTel = client
/// }
/// ```
extension TelemetryClient {
  /// Creates a test telemetry client backed by in-memory collectors.
  ///
  /// Also registers OTel global providers so that any code still using
  /// `OpenTelemetry.instance` sees the same providers.
  ///
  /// - Parameters:
  ///   - spanCollector: The in-memory span collector. Created if not provided.
  ///   - metricReader: Optional in-memory metric reader.
  ///   - errorDetailPolicy: Error detail policy for tests (default: `.redacted`).
  /// - Returns: A tuple of `(TelemetryClient, InMemorySpanCollector)`.
  public static func test(
    spanCollector: InMemorySpanCollector = InMemorySpanCollector(),
    metricReader: InMemoryMetricReader? = nil,
    errorDetailPolicy: ErrorDetailPolicy = .redacted
  ) -> (client: TelemetryClient, spanCollector: InMemorySpanCollector) {
    // Build tracer provider
    let processor = SimpleSpanProcessor(spanExporter: spanCollector)
    let tracerProvider = TracerProviderBuilder()
      .add(spanProcessor: processor)
      .build()
    OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

    let tracer = tracerProvider.get(
      instrumentationName: "ComposableOTel",
      instrumentationVersion: "0.1.0"
    )

    // Build meter provider
    let meter: any Meter
    if let metricReader {
      let meterProvider = MeterProviderSdk.builder()
        .registerMetricReader(reader: metricReader)
        .build()
      OpenTelemetry.registerMeterProvider(meterProvider: meterProvider)
      meter = meterProvider.get(name: "ComposableOTel")
    } else {
      meter = DefaultMeterProvider.instance.get(name: "ComposableOTel")
    }

    let client = TelemetryClient(
      tracer: tracer,
      metrics: MetricInstruments(meter: meter),
      errorDetailPolicy: errorDetailPolicy
    )

    return (client, spanCollector)
  }
}

/// The collectors returned by ``configureTestTelemetry(spanCollector:metricReader:)``.
@available(*, deprecated, message: "Use TelemetryClient.test() with withDependencies instead")
public struct TestTelemetry: Sendable {
  public let spanCollector: InMemorySpanCollector
  public let metricReader: InMemoryMetricReader?
}

/// Configure the global OpenTelemetry providers for testing with in-memory
/// collectors.
///
/// - Note: Prefer `TelemetryClient.test()` with `withDependencies` for new code.
@available(*, deprecated, message: "Use TelemetryClient.test() with withDependencies instead")
@discardableResult
public func configureTestTelemetry(
  spanCollector: InMemorySpanCollector = InMemorySpanCollector(),
  metricReader: InMemoryMetricReader? = nil
) -> TestTelemetry {
  let processor = SimpleSpanProcessor(spanExporter: spanCollector)
  let tracerProvider = TracerProviderBuilder()
    .add(spanProcessor: processor)
    .build()
  OpenTelemetry.registerTracerProvider(tracerProvider: tracerProvider)

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
