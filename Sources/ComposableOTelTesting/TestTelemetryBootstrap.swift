import ComposableOTel
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Container for in-memory test collectors returned by ``TelemetryClient/test(errorDetailPolicy:)``.
public struct TestCollectors: @unchecked Sendable {
  /// Collected spans from traced reducers, effects, and dependency calls.
  public let spans: InMemorySpanCollector
  /// Collected log records (from `telemetry.info()`, `telemetry.error()`, etc.).
  public let logs: InMemoryLogCollector
  /// Optional metric reader.
  public let metrics: InMemoryMetricReader?

  // TracerProviderSdk is thread-safe but not marked Sendable
  private let tracerProvider: TracerProviderSdk

  init(
    spans: InMemorySpanCollector,
    logs: InMemoryLogCollector,
    metrics: InMemoryMetricReader?,
    tracerProvider: TracerProviderSdk
  ) {
    self.spans = spans
    self.logs = logs
    self.metrics = metrics
    self.tracerProvider = tracerProvider
  }

  /// Flush all pending spans to the in-memory collector.
  ///
  /// Call this after exercising actions, before asserting on collected spans.
  public func forceFlush() {
    tracerProvider.forceFlush()
  }
}

/// Convenience factory for creating a ``TelemetryClient`` wired to in-memory
/// collectors, suitable for test assertions.
///
/// ```swift
/// let (client, collectors) = TelemetryClient.test()
/// let store = TestStore(...) {
///   MyFeature()
/// } withDependencies: {
///   $0.composableOTel = client
/// }
/// // After exercising actions:
/// collectors.spans.assertSpanExists(named: "reducer/MyFeature")
/// ```
extension TelemetryClient {
  /// Creates a test telemetry client backed by in-memory collectors.
  ///
  /// Also registers OTel global providers so that any code still using
  /// `OpenTelemetry.instance` sees the same providers.
  ///
  /// - Parameters:
  ///   - metricReader: Optional in-memory metric reader.
  ///   - errorDetailPolicy: Error detail policy for tests (default: `.redacted`).
  /// - Returns: A tuple of `(TelemetryClient, TestCollectors)`.
  public static func test(
    metricReader: InMemoryMetricReader? = nil,
    errorDetailPolicy: ErrorDetailPolicy = .redacted
  ) -> (client: TelemetryClient, collectors: TestCollectors) {
    // Build tracer provider
    let spanCollector = InMemorySpanCollector()
    let spanProcessor = SimpleSpanProcessor(spanExporter: spanCollector)
    let tracerProvider = TracerProviderBuilder()
      .add(spanProcessor: spanProcessor)
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

    // Build logger provider
    let logCollector = InMemoryLogCollector()
    let logProcessor = SimpleLogRecordProcessor(logRecordExporter: logCollector)
    let loggerProvider = LoggerProviderSdk(logRecordProcessors: [logProcessor])
    OpenTelemetry.registerLoggerProvider(loggerProvider: loggerProvider)

    let client = TelemetryClient(
      tracer: tracer,
      metrics: MetricInstruments(meter: meter),
      errorDetailPolicy: errorDetailPolicy
    )

    let collectors = TestCollectors(
      spans: spanCollector,
      logs: logCollector,
      metrics: metricReader,
      tracerProvider: tracerProvider
    )

    return (client, collectors)
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
