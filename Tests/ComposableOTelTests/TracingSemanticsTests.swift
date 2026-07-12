import ComposableArchitecture
import ComposableOTelTesting
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

private enum ExpectedError: Error, Equatable {
  case failed
}

@Reducer
private struct LifecycleFeature {
  struct State: Equatable {
    var completed = false
  }

  enum Action: Equatable {
    case start
    case completed
    case startCancellable
    case cancel
  }

  enum CancelID {
    case listener
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .start:
        return .tracedLongLivedRun(name: "longLived") { send in
          try await Task.sleep(for: .milliseconds(10))
          await send(.completed)
        }
      case .completed:
        state.completed = true
        return .none
      case .startCancellable:
        return .tracedLongLivedRun(name: "cancelledLongLived") { _ in
          try await Task.sleep(for: .seconds(30))
        }
        .cancellable(id: CancelID.listener)
      case .cancel:
        return .cancel(id: CancelID.listener)
      }
    }
  }
}

@Suite("Tracing semantics", .serialized)
struct TracingSemanticsTests {
  @Test("reducer span is the explicit parent of its traced effect")
  @MainActor
  func reducerEffectParent() async throws {
    let (client, collectors) = TelemetryClient.test()
    let store = TestStore(initialState: CounterFeature.State()) {
      CounterFeature()
    } withDependencies: {
      $0.composableOTel = client
    }

    await store.send(.fetchAndSet)
    await store.receive(.setCount(42)) {
      $0.count = 42
    }
    collectors.forceFlush()

    let reducerSpan = try #require(
      collectors.spans.spans(named: "reducer/CounterFeature").first {
        $0.attributes[TCAAttributes.actionType] == .string("fetchAndSet")
      }
    )
    let effectSpan = try #require(collectors.spans.spans(named: "effect/fetchCount").first)

    #expect(effectSpan.traceId == reducerSpan.traceId)
    #expect(effectSpan.parentSpanId == reducerSpan.spanId)
    #expect(effectSpan.status == .ok)
    #expect(effectSpan.attributes[TCAAttributes.effectOutcome] == .string("success"))
  }

  @Test("effect context survives await and inherited child tasks")
  func taskLocalPropagation() async throws {
    let (client, collectors) = TelemetryClient.test()

    try await withDependencies {
      $0.composableOTel = client
    } operation: {
      try await client.withEffectTrace(
        name: "propagation",
        longLived: false,
        parentContext: nil
      ) {
        try await Task.sleep(for: .milliseconds(1))
        _ = await tracedCall("awaited", method: "load") {
          1
        }
        _ = await Task {
          await tracedCall("childTask", method: "load") {
            2
          }
        }.value
      }
    }
    collectors.forceFlush()

    let effectSpan = try #require(collectors.spans.spans(named: "effect/propagation").first)
    let awaitedSpan = try #require(
      collectors.spans.spans(named: "dependency/awaited/load").first
    )
    let childTaskSpan = try #require(
      collectors.spans.spans(named: "dependency/childTask/load").first
    )

    #expect(awaitedSpan.traceId == effectSpan.traceId)
    #expect(awaitedSpan.parentSpanId == effectSpan.spanId)
    #expect(childTaskSpan.traceId == effectSpan.traceId)
    #expect(childTaskSpan.parentSpanId == effectSpan.spanId)
  }

  @Test("effect tracing records and rethrows failures")
  func errorRethrow() async throws {
    let (client, collectors) = TelemetryClient.test()

    do {
      let _: Void = try await client.withEffectTrace(
        name: "failure",
        longLived: false,
        parentContext: nil
      ) {
        throw ExpectedError.failed
      }
      Issue.record("Expected the traced operation to throw")
    } catch let error as ExpectedError {
      #expect(error == .failed)
    }
    collectors.forceFlush()

    let span = try #require(collectors.spans.spans(named: "effect/failure").first)
    #expect(span.status.isError)
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("error"))
    #expect(span.events.map(\.name) == ["exception"])
  }

  @Test("effect tracing records and rethrows cancellation")
  func cancellationRethrow() async throws {
    let (client, collectors) = TelemetryClient.test()
    let task = Task {
      try await client.withEffectTrace(
        name: "cancellation",
        longLived: false,
        parentContext: nil
      ) {
        try await Task.sleep(for: .seconds(30))
      }
    }

    await Task.yield()
    task.cancel()
    do {
      try await task.value
      Issue.record("Expected the traced operation to throw cancellation")
    } catch is CancellationError {
    }
    collectors.forceFlush()

    let span = try #require(collectors.spans.spans(named: "effect/cancellation").first)
    #expect(span.status == .unset)
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("cancelled"))
    #expect(span.attributes[TCAAttributes.effectCancelled] == .bool(true))
    #expect(span.events.map(\.name) == ["effect.cancelled"])
  }

  @Test("handled or translated cancellation follows the operation result")
  func handledCancellation() async throws {
    let (client, collectors) = TelemetryClient.test()
    let recoveredTask = Task {
      try await client.withEffectTrace(
        name: "recoveredCancellation",
        longLived: false,
        parentContext: nil
      ) {
        do {
          try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
        }
      }
    }
    await Task.yield()
    recoveredTask.cancel()
    try await recoveredTask.value

    let translatedTask = Task {
      try await client.withEffectTrace(
        name: "translatedCancellation",
        longLived: false,
        parentContext: nil
      ) {
        do {
          try await Task.sleep(for: .seconds(30))
        } catch is CancellationError {
          throw ExpectedError.failed
        }
      }
    }
    await Task.yield()
    translatedTask.cancel()
    do {
      try await translatedTask.value
      Issue.record("Expected cancellation to be translated into the host error")
    } catch let error as ExpectedError {
      #expect(error == .failed)
    }
    collectors.forceFlush()

    let recovered = try #require(
      collectors.spans.spans(named: "effect/recoveredCancellation").first
    )
    let translated = try #require(
      collectors.spans.spans(named: "effect/translatedCancellation").first
    )
    #expect(recovered.attributes[TCAAttributes.effectOutcome] == .string("success"))
    #expect(recovered.status == .ok)
    #expect(translated.attributes[TCAAttributes.effectOutcome] == .string("error"))
    #expect(translated.status.isError)
  }

  @Test("long-lived effects use one span and classify normal completion")
  @MainActor
  func longLivedCompletion() async throws {
    let (client, collectors) = TelemetryClient.test()
    let store = TestStore(initialState: LifecycleFeature.State()) {
      LifecycleFeature()
    } withDependencies: {
      $0.composableOTel = client
    }

    await store.send(.start)
    await store.receive(.completed) {
      $0.completed = true
    }
    await store.finish()
    collectors.forceFlush()

    let spans = collectors.spans.spans(named: "effect/longLived")
    let span = try #require(spans.first)
    #expect(spans.count == 1)
    #expect(span.status == .ok)
    #expect(span.attributes[TCAAttributes.effectLongLived] == .bool(true))
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("success"))
    #expect(span.events.map(\.name) == ["effect.completed"])
  }

  @Test("long-lived cancellation is not completion")
  @MainActor
  func longLivedCancellation() async throws {
    let (client, collectors) = TelemetryClient.test()
    let store = TestStore(initialState: LifecycleFeature.State()) {
      LifecycleFeature()
    } withDependencies: {
      $0.composableOTel = client
    }

    await store.send(.startCancellable)
    await store.send(.cancel)
    await store.finish()
    collectors.forceFlush()

    let span = try #require(
      collectors.spans.spans(named: "effect/cancelledLongLived").first
    )
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("cancelled"))
    #expect(span.events.map(\.name) == ["effect.cancelled"])
  }

  @Test("effect counters and active accounting are balanced exactly once")
  func balancedEffectMetrics() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, _) = TelemetryClient.test(metricReader: metricReader)

    try await client.withEffectTrace(
      name: "success",
      longLived: false,
      parentContext: nil
    ) {}
    try await client.withEffectTrace(
      name: "longLivedSuccess",
      longLived: true,
      parentContext: nil
    ) {}
    do {
      let _: Void = try await client.withEffectTrace(
        name: "error",
        longLived: false,
        parentContext: nil
      ) {
        throw ExpectedError.failed
      }
    } catch is ExpectedError {
    }

    let cancelledTask = Task {
      try await client.withEffectTrace(
        name: "cancelled",
        longLived: true,
        parentContext: nil
      ) {
        try await Task.sleep(for: .seconds(30))
      }
    }
    await Task.yield()
    cancelledTask.cancel()
    _ = try? await cancelledTask.value

    let metrics = metricReader.collectMetrics()
    #expect(sumLongPoints(named: "tca.effects.started", in: metrics) == 4)
    #expect(sumLongPoints(named: "tca.effects.completed", in: metrics) == 2)
    #expect(sumLongPoints(named: "tca.effects.cancelled", in: metrics) == 1)
    #expect(sumLongPoints(named: "tca.effects.errored", in: metrics) == 1)

    let activePoints = longPoints(named: "tca.store.active_effects", in: metrics)
    #expect(activePoints.count == 4)
    #expect(activePoints.allSatisfy { $0.value == 0 })
  }

  @Test("test clients retain isolated cached loggers under concurrency")
  func injectedLoggerIsolation() async {
    let (firstClient, firstCollectors) = TelemetryClient.test()
    let (secondClient, secondCollectors) = TelemetryClient.test()

    firstClient.info("first")
    secondClient.info("second")
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<64 {
        group.addTask {
          firstClient.info("concurrent-\(index)")
        }
      }
    }

    #expect(firstCollectors.logs.records(containing: "first").count == 1)
    #expect(firstCollectors.logs.records(containing: "concurrent-").count == 64)
    #expect(firstCollectors.logs.records(containing: "second").isEmpty)
    #expect(secondCollectors.logs.records(containing: "second").count == 1)
    #expect(secondCollectors.logs.records(containing: "first").isEmpty)
  }

  @Test("bootstrap is atomic, idempotent, and unaffected by prior default-client access")
  func concurrentBootstrap() async {
    let defaultClient = currentTelemetryClient()
    let clients = await withTaskGroup(
      of: TelemetryClient.self,
      returning: [TelemetryClient].self
    ) { group in
      for index in 0..<32 {
        group.addTask {
          TelemetryBootstrap.configure(
            serviceName: "bootstrap-\(index)",
            environment: .production(endpoint: "https://unused.invalid")
          )
        }
      }
      var clients: [TelemetryClient] = []
      for await client in group {
        clients.append(client)
      }
      return clients
    }

    let first = clients[0]
    #expect(defaultClient.metrics !== first.metrics)
    #expect(clients.allSatisfy { $0.metrics === first.metrics })

    let repeated = TelemetryBootstrap.configure(
      serviceName: "ignored-after-first-configuration",
      environment: .debug
    )
    #expect(repeated.metrics === first.metrics)
  }
}

private func currentTelemetryClient() -> TelemetryClient {
  @Dependency(\.composableOTel) var telemetry
  return telemetry
}

private func longPoints(named name: String, in metrics: [MetricData]) -> [LongPointData] {
  metrics
    .filter { $0.name == name }
    .flatMap(\.data.points)
    .compactMap { $0 as? LongPointData }
}

private func sumLongPoints(named name: String, in metrics: [MetricData]) -> Int {
  longPoints(named: name, in: metrics).reduce(0) { $0 + $1.value }
}
