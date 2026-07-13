import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk

func runtimePointBoundedBatches<Element>(
  _ elements: [Element],
  maximumPoints: Int?,
  pointCount: (Element) -> Int
) -> (batches: [[Element]], droppedPoints: Int) {
  guard let maximumPoints else {
    return (elements.isEmpty ? [] : [elements], 0)
  }
  var batches = [[Element]]()
  var current = [Element]()
  var currentPointCount = 0
  var droppedPoints = 0
  for element in elements {
    let count = pointCount(element)
    if count > maximumPoints {
      droppedPoints += count
      continue
    }
    if !current.isEmpty, currentPointCount + count > maximumPoints {
      batches.append(current)
      current.removeAll(keepingCapacity: true)
      currentPointCount = 0
    }
    current.append(element)
    currentPointCount += count
  }
  if !current.isEmpty {
    batches.append(current)
  }
  return (batches, droppedPoints)
}

private final class RuntimeRequestCaptureHTTPClient: HTTPClient, @unchecked Sendable {
  private let lock = NSLock()
  private var request: URLRequest?

  func capture<Result>(_ operation: () -> Result) -> (Result, URLRequest?) {
    lock.withLock {
      self.request = nil
    }
    let result = operation()
    let request = lock.withLock {
      defer { self.request = nil }
      return self.request
    }
    return (result, request)
  }

  func send(
    request: URLRequest,
    completion: @escaping (Result<HTTPURLResponse, any Error>) -> Void
  ) {
    lock.withLock {
      self.request = request
    }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 202,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )
    else {
      completion(.failure(TelemetryRuntimeTransportError.invalidResponse))
      return
    }
    completion(.success(response))
  }
}

final class RuntimeEncodedRequestDispatcher<Item: Sendable>: @unchecked Sendable {
  private let maximumEncodedRequestBytes: Int
  private let deliveryClient: RuntimeOTLPHTTPClient

  init(
    maximumEncodedRequestBytes: Int,
    deliveryClient: RuntimeOTLPHTTPClient
  ) {
    self.maximumEncodedRequestBytes = maximumEncodedRequestBytes
    self.deliveryClient = deliveryClient
  }

  func dispatch(
    _ items: [Item],
    encode: ([Item]) -> URLRequest?
  ) -> Bool {
    guard !items.isEmpty, let request = encode(items) else { return false }
    if accepts(request) || items.count == 1 {
      return send(request)
    }

    let midpoint = items.count / 2
    let first = Array(items[..<midpoint])
    let second = Array(items[midpoint...])
    let firstSucceeded = dispatch(first, encode: encode)
    let secondSucceeded = dispatch(second, encode: encode)
    return firstSucceeded && secondSucceeded
  }

  private func accepts(_ request: URLRequest) -> Bool {
    request.httpBodyStream == nil
      && (request.httpBody?.count ?? 0) <= maximumEncodedRequestBytes
  }

  private func send(_ request: URLRequest) -> Bool {
    var succeeded = false
    deliveryClient.send(request: request) { result in
      if case .success = result {
        succeeded = true
      }
    }
    return succeeded
  }
}

final class RuntimeByteBoundedSpanExporter: SpanExporter, @unchecked Sendable {
  private let capture = RuntimeRequestCaptureHTTPClient()
  private let exporter: OtlpHttpTraceExporter
  private let dispatcher: RuntimeEncodedRequestDispatcher<SpanData>
  private let encodingLock = NSLock()

  init(
    endpoint: URL,
    maximumEncodedRequestBytes: Int,
    deliveryClient: RuntimeOTLPHTTPClient
  ) {
    exporter = OtlpHttpTraceExporter(
      endpoint: endpoint,
      httpClient: capture,
      envVarHeaders: []
    )
    dispatcher = RuntimeEncodedRequestDispatcher(
      maximumEncodedRequestBytes: maximumEncodedRequestBytes,
      deliveryClient: deliveryClient
    )
  }

  func export(
    spans: [SpanData],
    explicitTimeout: TimeInterval?
  ) -> SpanExporterResultCode {
    encodingLock.withLock {
      dispatcher.dispatch(spans) { subset in
        let (_, request) = capture.capture {
          exporter.export(spans: subset, explicitTimeout: explicitTimeout)
        }
        return request
      } ? .success : .failure
    }
  }

  func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
    exporter.flush(explicitTimeout: explicitTimeout)
  }

  func shutdown(explicitTimeout: TimeInterval?) {
    exporter.shutdown(explicitTimeout: explicitTimeout)
  }
}

final class RuntimeByteBoundedLogExporter: LogRecordExporter, @unchecked Sendable {
  private let capture = RuntimeRequestCaptureHTTPClient()
  private let exporter: OtlpHttpLogExporter
  private let dispatcher: RuntimeEncodedRequestDispatcher<ReadableLogRecord>
  private let encodingLock = NSLock()

  init(
    endpoint: URL,
    maximumEncodedRequestBytes: Int,
    deliveryClient: RuntimeOTLPHTTPClient
  ) {
    exporter = OtlpHttpLogExporter(
      endpoint: endpoint,
      httpClient: capture,
      envVarHeaders: []
    )
    dispatcher = RuntimeEncodedRequestDispatcher(
      maximumEncodedRequestBytes: maximumEncodedRequestBytes,
      deliveryClient: deliveryClient
    )
  }

  func export(
    logRecords: [ReadableLogRecord],
    explicitTimeout: TimeInterval?
  ) -> ExportResult {
    encodingLock.withLock {
      dispatcher.dispatch(logRecords) { subset in
        let (_, request) = capture.capture {
          exporter.export(logRecords: subset, explicitTimeout: explicitTimeout)
        }
        return request
      } ? .success : .failure
    }
  }

  func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
    exporter.forceFlush(explicitTimeout: explicitTimeout)
  }

  func shutdown(explicitTimeout: TimeInterval?) {
    exporter.shutdown(explicitTimeout: explicitTimeout)
  }
}

final class RuntimeByteBoundedMetricExporter: MetricExporter, @unchecked Sendable {
  private let capture = RuntimeRequestCaptureHTTPClient()
  private let exporter: OtlpHttpMetricExporter
  private let dispatcher: RuntimeEncodedRequestDispatcher<MetricData>
  private let maximumPointsPerRequest: Int?
  private let diagnostics: RuntimeDiagnosticsState?
  private let encodingLock = NSLock()

  init(
    endpoint: URL,
    maximumEncodedRequestBytes: Int,
    maximumPointsPerRequest: Int? = nil,
    diagnostics: RuntimeDiagnosticsState? = nil,
    deliveryClient: RuntimeOTLPHTTPClient
  ) {
    self.maximumPointsPerRequest = maximumPointsPerRequest
    self.diagnostics = diagnostics
    exporter = OtlpHttpMetricExporter(
      endpoint: endpoint,
      httpClient: capture,
      envVarHeaders: []
    )
    dispatcher = RuntimeEncodedRequestDispatcher(
      maximumEncodedRequestBytes: maximumEncodedRequestBytes,
      deliveryClient: deliveryClient
    )
  }

  func export(metrics: [MetricData]) -> ExportResult {
    encodingLock.withLock {
      let bounded = runtimePointBoundedBatches(
        metrics,
        maximumPoints: maximumPointsPerRequest,
        pointCount: { $0.data.points.count }
      )
      if bounded.droppedPoints > 0 {
        diagnostics?.recordMetricPointLimitExceeded(count: bounded.droppedPoints)
      }

      var succeeded = bounded.droppedPoints == 0
      for batch in bounded.batches {
        let dispatched = dispatcher.dispatch(batch) { subset in
          let (_, request) = capture.capture {
            exporter.export(metrics: subset)
          }
          return request
        }
        succeeded = dispatched && succeeded
      }
      return succeeded ? .success : .failure
    }
  }

  func flush() -> ExportResult {
    exporter.flush()
  }

  func shutdown() -> ExportResult {
    exporter.shutdown()
  }

  func getAggregationTemporality(
    for instrument: InstrumentType
  ) -> AggregationTemporality {
    exporter.getAggregationTemporality(for: instrument)
  }

  func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation {
    exporter.getDefaultAggregation(for: instrument)
  }
}
