import ComposableArchitecture
import ComposableOTel
import ComposableOTelExporters
import Darwin
import Dependencies
import Foundation

private struct Budgets: Decodable {
  struct Gateway: Decodable {
    let maximumEncodedRequestBytes: Int
    let maximumSignalsPerBatch: Int
  }

  struct Queue: Decodable {
    let items: Int
    let maximumResidentDeltaBytes: Int64
  }

  let schemaVersion: Int
  let benchmarks: [String: UInt64]
  let gateway: Gateway
  let maximumSampledToUnsampledRatio: Double
  let queue: Queue
}

private actor EncodedRequestCapture {
  private var sizes: [Int] = []

  nonisolated var transport: TelemetryHTTPTransport {
    TelemetryHTTPTransport { [weak self] request in
      guard let self else { throw CancellationError() }
      return await self.send(request)
    }
  }

  var bodySizes: [Int] {
    sizes
  }

  private func send(_ request: URLRequest) -> TelemetryHTTPResponse {
    sizes.append(request.httpBody?.count ?? 0)
    return TelemetryHTTPResponse(statusCode: 202)
  }
}

private struct Result: Codable {
  let name: String
  let iterations: Int
  let nanosecondsPerOperation: UInt64
  let budgetNanosecondsPerOperation: UInt64
  let passed: Bool
}

private struct BenchmarkContractPayload: Sendable {
  let event: TelemetryEnumValue
  let success: Bool
}

private enum BenchmarkFailure: Error, CustomStringConvertible {
  case invalidBudgets
  case regression(String)

  var description: String {
    switch self {
    case .invalidBudgets:
      "Benchmark budgets are missing or invalid"
    case .regression(let message):
      message
    }
  }
}

@Reducer
private struct BenchmarkFeature {
  struct State: Equatable {
    var count = 0
  }

  enum Action: Equatable {
    case increment
    case effect
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += 1
        return .none
      case .effect:
        return .tracedRun(effect: "benchmark-effect") { _ in }
      }
    }
    .instrumented(
      feature: "benchmark",
      action: {
        switch $0 {
        case .increment: "increment"
        case .effect: "effect"
        }
      }
    )
  }
}

@Reducer
private struct StateChangeBenchmarkFeature {
  struct State: Equatable {
    var count = 0
  }

  enum Action: Equatable {
    case increment
  }

  var body: some ReducerOf<Self> {
    Reduce { state, _ in
      state.count += 1
      return .none
    }
    .instrumented(
      feature: "benchmark",
      action: { _ in "increment" },
      stateChangeToken: { StateChangeToken(UInt64($0.count)) }
    )
  }
}

@main
private enum ReleaseBenchmarks {
  @MainActor
  static func main() async throws {
    let budgets = try loadBudgets()
    guard budgets.schemaVersion == 1 else {
      throw BenchmarkFailure.invalidBudgets
    }

    let maximumIdentifier = String(repeating: "a", count: 48)
    let maximumRoute = RouteID(validating: maximumIdentifier)!
    let schema = try TelemetrySchema(
      features: ["benchmark"],
      actions: ["increment", "effect"],
      effects: ["benchmark-effect"],
      dependencies: ["benchmark-dependency"],
      operations: ["load"],
      routes: ["benchmark-route", maximumRoute],
      services: ["benchmark"]
    )
    let endpoint = URL(string: "https://benchmark.invalid/otlp")!
    let transport = TelemetryHTTPTransport { _ in
      TelemetryHTTPResponse(statusCode: 202)
    }
    let eventKey = try TelemetryFieldKey("benchmark.event")
    let successKey = try TelemetryFieldKey("benchmark.success")
    let events: Set<TelemetryEnumValue> = [try .init("first"), try .init("second")]
    let contractFields: [TelemetryField<BenchmarkContractPayload>] = [
      try .enumeration(eventKey, allowedValues: events) { $0.event },
      .boolean(successKey) { $0.success },
    ]
    let contractSpan = try TelemetrySpanDefinition(
      name: TelemetryContractName("benchmark.contract"),
      fields: contractFields
    )
    let contractLog = try TelemetryLogDefinition(
      eventName: TelemetryContractName("benchmark.contract.event"),
      severity: .info,
      bodyPolicy: .none,
      fields: contractFields
    )
    let contractCounter = try TelemetryCounterDefinition(
      name: TelemetryContractName("benchmark.contract.events"),
      unit: TelemetryStringValue("{event}"),
      description: TelemetryStringValue("benchmark-contract-events"),
      maximumSeries: 4,
      fields: contractFields
    )
    let contractCatalog = try TelemetryContractCatalog(
      contractVersion: .init(1),
      spans: [.init(contractSpan)],
      logs: [.init(contractLog)],
      counters: [.init(contractCounter)]
    )
    let contractPayload = BenchmarkContractPayload(
      event: try .init("first"),
      success: true
    )

    let fullRuntime = try runtime(
      schema: schema,
      endpoint: endpoint,
      transport: transport,
      samplingRatio: 1,
      signals: .init(tracesEnabled: true, metricsEnabled: true, logsEnabled: true),
      catalog: contractCatalog
    )
    await fullRuntime.setExportCondition(.unavailable)

    let disabledRuntime = try runtime(
      schema: schema,
      endpoint: endpoint,
      transport: transport,
      samplingRatio: 0,
      signals: .disabled
    )
    let unsampledRuntime = try runtime(
      schema: schema,
      endpoint: endpoint,
      transport: transport,
      samplingRatio: 0,
      signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false)
    )
    await unsampledRuntime.setExportCondition(.unavailable)
    let loggingRuntime = try runtime(
      schema: schema,
      endpoint: endpoint,
      transport: transport,
      samplingRatio: 0,
      signals: .init(tracesEnabled: false, metricsEnabled: false, logsEnabled: true)
    )
    await loggingRuntime.setExportCondition(.unavailable)
    let metricsRuntime = try runtime(
      schema: schema,
      endpoint: endpoint,
      transport: transport,
      samplingRatio: 0,
      signals: .init(tracesEnabled: false, metricsEnabled: true, logsEnabled: false)
    )

    let memoryBefore = residentHighWaterBytes()
    let queueRuntime = try runtime(
      schema: schema,
      endpoint: endpoint,
      transport: transport,
      samplingRatio: 1,
      signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false),
      maximumQueueSize: 1,
      maximumBatchSize: 1,
      maximumPendingBatches: budgets.queue.items
    )
    await queueRuntime.setExportCondition(.unavailable)
    for _ in 0..<(budgets.queue.items * 2) {
      queueRuntime.client.recordNavigation(.push, route: "benchmark-route")
    }
    _ = await queueRuntime.forceFlush(timeout: .milliseconds(100))
    let expectedQueueAccounting = budgets.queue.items * 2
    let queueDeadline = ContinuousClock().now.advanced(by: .seconds(10))
    while true {
      let diagnostics = queueRuntime.diagnostics.traces
      if diagnostics.queueDepth + diagnostics.droppedItems + diagnostics.successes
        >= expectedQueueAccounting
      {
        break
      }
      guard ContinuousClock().now < queueDeadline else {
        throw BenchmarkFailure.regression("Queue accounting did not settle before the deadline")
      }
      try await Task.sleep(for: .milliseconds(1))
    }
    let memoryDelta = max(0, residentHighWaterBytes() - memoryBefore)
    let queueDiagnostics = queueRuntime.diagnostics.traces
    guard
      queueDiagnostics.queueDepth <= budgets.queue.items,
      queueDiagnostics.queueDepth > 0,
      queueDiagnostics.droppedItems > 0,
      queueDiagnostics.queueDepth + queueDiagnostics.droppedItems + queueDiagnostics.successes
        == expectedQueueAccounting,
      memoryDelta <= budgets.queue.maximumResidentDeltaBytes
    else {
      throw BenchmarkFailure.regression(
        "Queue budget failed: depth=\(queueDiagnostics.queueDepth), "
          + "drops=\(queueDiagnostics.droppedItems), successes=\(queueDiagnostics.successes), "
          + "memoryDelta=\(memoryDelta)"
      )
    }

    let batchingRuntime = try runtime(
      schema: schema,
      endpoint: endpoint,
      transport: transport,
      samplingRatio: 1,
      signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false),
      maximumQueueSize: 250,
      maximumBatchSize: 50
    )
    let encodedCapture = EncodedRequestCapture()
    let gatewayRuntime = try runtime(
      schema: schema,
      endpoint: endpoint,
      transport: encodedCapture.transport,
      samplingRatio: 1,
      signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false),
      maximumQueueSize: budgets.gateway.maximumSignalsPerBatch,
      maximumBatchSize: budgets.gateway.maximumSignalsPerBatch,
      maximumPendingBatches: 1,
      maximumEncodedRequestBytes: budgets.gateway.maximumEncodedRequestBytes,
      requestTimeout: .seconds(5)
    )

    var results: [Result] = []
    results.append(
      try await measure(
        name: "reducerDisabled",
        iterations: 20_000,
        budget: budgets
      ) {
        var state = BenchmarkFeature.State()
        let reducer = BenchmarkFeature()
        return {
          _ = withDependencies {
            $0.composableOTel = disabledRuntime.client
          } operation: {
            reducer._reduce(into: &state, action: .increment)
          }
        }
      }
    )
    results.append(
      try await measure(name: "reducer", iterations: 10_000, budget: budgets) {
        var state = BenchmarkFeature.State()
        let reducer = BenchmarkFeature()
        return {
          _ = withDependencies {
            $0.composableOTel = fullRuntime.client
          } operation: {
            reducer._reduce(into: &state, action: .increment)
          }
        }
      }
    )
    results.append(
      try await measure(name: "stateChange", iterations: 10_000, budget: budgets) {
        var state = StateChangeBenchmarkFeature.State()
        let reducer = StateChangeBenchmarkFeature()
        return {
          _ = withDependencies {
            $0.composableOTel = fullRuntime.client
          } operation: {
            reducer._reduce(into: &state, action: .increment)
          }
        }
      }
    )
    results.append(
      try await measure(name: "dependency", iterations: 5_000, budget: budgets) {
        {
          _ = await withDependencies {
            $0.composableOTel = fullRuntime.client
          } operation: {
            await tracedCall(dependency: "benchmark-dependency", operation: "load") { 1 }
          }
        }
      }
    )
    results.append(
      try await measure(name: "catalogSpan", iterations: 3_000, budget: budgets) {
        {
          try! await fullRuntime.client.withSpan(
            contractSpan,
            payload: contractPayload
          ) {}
        }
      }
    )
    results.append(
      try await measure(name: "catalogLog", iterations: 10_000, budget: budgets) {
        {
          try! fullRuntime.client.record(contractLog, payload: contractPayload)
        }
      }
    )
    results.append(
      try await measure(name: "catalogCounter", iterations: 20_000, budget: budgets) {
        {
          try! fullRuntime.client.add(
            contractCounter,
            delta: TelemetryCounterDelta(1),
            payload: contractPayload
          )
        }
      }
    )
    results.append(
      try await measure(name: "effect", iterations: 2_000, budget: budgets) {
        let store = Store(initialState: BenchmarkFeature.State()) {
          BenchmarkFeature()
        } withDependencies: {
          $0.composableOTel = fullRuntime.client
        }
        return {
          await store.send(.effect).finish()
        }
      }
    )
    results.append(
      try await measure(name: "logging", iterations: 10_000, budget: budgets) {
        {
          loggingRuntime.client.recordNavigation(.push, route: "benchmark-route")
        }
      }
    )
    results.append(
      try await measure(name: "metrics", iterations: 20_000, budget: budgets) {
        {
          metricsRuntime.client.recordNavigation(.push, route: "benchmark-route")
        }
      }
    )
    let sampledToUnsampledRatio = await measureRatio(iterations: 5_000) {
      fullRuntime.client.recordNavigation(.push, route: "benchmark-route")
    } denominator: {
      unsampledRuntime.client.recordNavigation(.push, route: "benchmark-route")
    }
    results.append(
      try await measure(name: "sampledSpan", iterations: 5_000, budget: budgets) {
        {
          fullRuntime.client.recordNavigation(.push, route: "benchmark-route")
        }
      }
    )
    results.append(
      try await measure(name: "unsampledSpan", iterations: 10_000, budget: budgets) {
        {
          unsampledRuntime.client.recordNavigation(.push, route: "benchmark-route")
        }
      }
    )
    results.append(
      try await measure(name: "batching", iterations: 5_000, budget: budgets) {
        {
          batchingRuntime.client.recordNavigation(.push, route: "benchmark-route")
        }
      }
    )
    _ = await batchingRuntime.forceFlush(timeout: .seconds(5))
    for _ in 0..<budgets.gateway.maximumSignalsPerBatch {
      gatewayRuntime.client.recordNavigation(.push, route: maximumRoute)
    }
    let gatewayResult = await gatewayRuntime.forceFlush(timeout: .seconds(5))
    let encodedBodySizes = await encodedCapture.bodySizes
    guard
      gatewayResult.traces.status == .success,
      encodedBodySizes.count == 1,
      let maximumEncodedBody = encodedBodySizes.max(),
      maximumEncodedBody <= budgets.gateway.maximumEncodedRequestBytes,
      gatewayRuntime.diagnostics.traces.oversizedRequests == 0
    else {
      throw BenchmarkFailure.regression(
        "Conservative gateway batch exceeded its encoded request budget"
      )
    }

    if sampledToUnsampledRatio > budgets.maximumSampledToUnsampledRatio {
      throw BenchmarkFailure.regression(
        String(
          format: "Sampled/unsampled ratio %.2f exceeds %.2f",
          sampledToUnsampledRatio,
          budgets.maximumSampledToUnsampledRatio
        )
      )
    }

    for result in results {
      print(
        "\(result.name): \(result.nanosecondsPerOperation) ns/op "
          + "(budget \(result.budgetNanosecondsPerOperation), "
          + "\(result.passed ? "PASS" : "FAIL"))"
      )
    }
    print(String(format: "sampled/unsampled ratio: %.2f", sampledToUnsampledRatio))
    print(
      "queue: depth \(queueDiagnostics.queueDepth), drops \(queueDiagnostics.droppedItems), "
        + "successes \(queueDiagnostics.successes), "
        + "resident high-water delta \(memoryDelta) bytes"
    )
    print(
      "gateway batch: \(budgets.gateway.maximumSignalsPerBatch) signals, "
        + "\(encodedBodySizes.max() ?? 0) encoded bytes "
        + "(budget \(budgets.gateway.maximumEncodedRequestBytes))"
    )

    if let outputIndex = CommandLine.arguments.firstIndex(of: "--output") {
      let pathIndex = CommandLine.arguments.index(after: outputIndex)
      guard pathIndex < CommandLine.arguments.endIndex else {
        throw BenchmarkFailure.invalidBudgets
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(results).write(
        to: URL(fileURLWithPath: CommandLine.arguments[pathIndex]),
        options: .atomic
      )
    }

    _ = await fullRuntime.shutdown(timeout: .milliseconds(100))
    _ = await disabledRuntime.shutdown(timeout: .milliseconds(100))
    _ = await unsampledRuntime.shutdown(timeout: .milliseconds(100))
    _ = await loggingRuntime.shutdown(timeout: .milliseconds(100))
    _ = await metricsRuntime.shutdown(timeout: .milliseconds(100))
    _ = await queueRuntime.shutdown(timeout: .milliseconds(100))
    _ = await batchingRuntime.shutdown(timeout: .milliseconds(100))
    _ = await gatewayRuntime.shutdown(timeout: .milliseconds(100))
  }

  private static func loadBudgets() throws -> Budgets {
    try JSONDecoder().decode(
      Budgets.self,
      from: Data(contentsOf: Bundle.module.url(forResource: "Budgets", withExtension: "json")!)
    )
  }

  private static func runtime(
    schema: TelemetrySchema,
    endpoint: URL,
    transport: TelemetryHTTPTransport,
    samplingRatio: Double,
    signals: TelemetrySignalConfiguration,
    catalog: TelemetryContractCatalog = .empty,
    maximumQueueSize: Int = 65_536,
    maximumBatchSize: Int? = nil,
    maximumPendingBatches: Int = 1024,
    maximumEncodedRequestBytes: Int = 64 * 1_024,
    requestTimeout: Duration = .seconds(10)
  ) throws -> TelemetryRuntime {
    try TelemetryRuntime(
      configuration: .init(
        serviceName: "benchmark",
        endpoints: .init(baseURL: endpoint),
        samplingRatio: samplingRatio,
        policy: TelemetryPolicy(schema: schema, catalog: catalog, signals: signals),
        traces: .init(
          maximumQueueSize: maximumQueueSize,
          maximumBatchSize: maximumBatchSize ?? maximumQueueSize,
          scheduledDelay: .seconds(60)
        ),
        logs: .init(
          maximumQueueSize: maximumQueueSize,
          maximumBatchSize: maximumBatchSize ?? maximumQueueSize,
          scheduledDelay: .seconds(60)
        ),
        metricExportInterval: .seconds(60),
        delivery: .init(
          maximumPendingBatches: maximumPendingBatches,
          maximumEncodedRequestBytes: maximumEncodedRequestBytes,
          requestTimeout: requestTimeout
        ),
        defaultFlushTimeout: .milliseconds(100),
        backgroundFlushTimeout: .milliseconds(100)
      ),
      transport: transport,
      authenticator: .none
    )
  }

  @MainActor
  private static func measure(
    name: String,
    iterations: Int,
    budget: Budgets,
    operation: @MainActor () async throws -> (@MainActor () async -> Void)
  ) async throws -> Result {
    guard let maximum = budget.benchmarks[name], iterations > 0 else {
      throw BenchmarkFailure.invalidBudgets
    }
    let body = try await operation()
    for _ in 0..<min(iterations, 100) {
      await body()
    }

    var samples: [UInt64] = []
    let clock = ContinuousClock()
    for _ in 0..<5 {
      let start = clock.now
      for _ in 0..<iterations {
        await body()
      }
      let elapsed = clock.now - start
      let components = elapsed.components
      let nanoseconds =
        UInt64(max(0, components.seconds)) * 1_000_000_000
        + UInt64(max(0, components.attoseconds / 1_000_000_000))
      samples.append(nanoseconds / UInt64(iterations))
    }
    samples.sort()
    let measured = samples[samples.count / 2]
    let result = Result(
      name: name,
      iterations: iterations,
      nanosecondsPerOperation: measured,
      budgetNanosecondsPerOperation: maximum,
      passed: measured <= maximum
    )
    if !result.passed {
      throw BenchmarkFailure.regression(
        "\(name) measured \(measured) ns/op, above budget \(maximum)"
      )
    }
    return result
  }

  @MainActor
  private static func measureRatio(
    iterations: Int,
    numerator: @MainActor () async -> Void,
    denominator: @MainActor () async -> Void
  ) async -> Double {
    for _ in 0..<100 {
      await numerator()
      await denominator()
    }

    func measure(_ operation: @MainActor () async -> Void) async -> UInt64 {
      let clock = ContinuousClock()
      let start = clock.now
      for _ in 0..<iterations {
        await operation()
      }
      let components = (clock.now - start).components
      return UInt64(max(0, components.seconds)) * 1_000_000_000
        + UInt64(max(0, components.attoseconds / 1_000_000_000))
    }

    var ratios: [Double] = []
    for sample in 0..<5 {
      let numeratorNanoseconds: UInt64
      let denominatorNanoseconds: UInt64
      if sample.isMultiple(of: 2) {
        numeratorNanoseconds = await measure(numerator)
        denominatorNanoseconds = await measure(denominator)
      } else {
        denominatorNanoseconds = await measure(denominator)
        numeratorNanoseconds = await measure(numerator)
      }
      ratios.append(
        Double(numeratorNanoseconds) / Double(max(1, denominatorNanoseconds))
      )
    }
    ratios.sort()
    return ratios[ratios.count / 2]
  }

  private static func residentHighWaterBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
  }
}
