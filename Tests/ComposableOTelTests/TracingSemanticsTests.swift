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
        return .tracedLongLivedRun(effect: "long-lived") { send in
          try await Task.sleep(for: .milliseconds(10))
          await send(.completed)
        }
      case .completed:
        state.completed = true
        return .none
      case .startCancellable:
        return .tracedLongLivedRun(effect: "cancelled-long-lived") { _ in
          try await Task.sleep(for: .seconds(30))
        }
        .cancellable(id: CancelID.listener)
      case .cancel:
        return .cancel(id: CancelID.listener)
      }
    }
  }
}

@Reducer
private struct MarkerFeature {
  struct State: Equatable {}
  enum Action: Equatable {
    case start
  }

  var body: some ReducerOf<Self> {
    Reduce { _, action in
      switch action {
      case .start:
        return Effect<Action>.run { _ in
          try await Task.sleep(for: .milliseconds(1))
        }
        .traceStart(effect: "fetch-count")
      }
    }
    .instrumented(feature: "counter", action: { _ in "fetch-and-set" })
  }
}

@Reducer
private struct CatchFeature {
  struct State: Equatable {
    var handled = false
  }

  enum Action: Equatable {
    case start
    case errorHandled
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .start:
        return .tracedRun(effect: "failure") { send in
          do {
            throw ExpectedError.failed
          } catch {
            await send(.errorHandled)
          }
        }
      case .errorHandled:
        state.handled = true
        return .none
      }
    }
    .instrumented(feature: "counter", action: { _ in "fetch-and-set" })
  }
}

@Suite("Tracing semantics", .serialized)
struct TracingSemanticsTests {
  @Test("reducer span is the explicit parent of its traced effect")
  @MainActor
  func reducerEffectParent() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())
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
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.reducer).first {
        $0.attributes[TCAAttributes.actionName] == .string("fetch-and-set")
      }
    )
    let effectSpan = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first {
        $0.attributes[TCAAttributes.effectName] == .string("fetch-count")
      }
    )
    #expect(effectSpan.traceId == reducerSpan.traceId)
    #expect(effectSpan.parentSpanId == reducerSpan.spanId)
    #expect(effectSpan.status == .ok)
    #expect(effectSpan.attributes[TCAAttributes.effectOutcome] == .string("success"))
  }

  @Test("effect context survives await and inherited child tasks")
  func taskLocalPropagation() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())

    try await withDependencies {
      $0.composableOTel = client
    } operation: {
      try await client.withEffectTrace(
        effect: "propagation",
        longLived: false,
        parentContext: nil
      ) {
        try await Task.sleep(for: .milliseconds(1))
        _ = await tracedCall(dependency: "awaited", operation: "load") { 1 }
        _ = await Task {
          await tracedCall(dependency: "child-task", operation: "load") { 2 }
        }.value
      }
    }
    collectors.forceFlush()

    let effectSpan = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first {
        $0.attributes[TCAAttributes.effectName] == .string("propagation")
      }
    )
    let dependencySpans = collectors.spans.spans(
      named: ComposableOTelSemantics.Spans.dependency
    )
    let awaitedSpan = try #require(
      dependencySpans.first {
        $0.attributes[TCAAttributes.dependencyName] == .string("awaited")
      }
    )
    let childTaskSpan = try #require(
      dependencySpans.first {
        $0.attributes[TCAAttributes.dependencyName] == .string("child-task")
      }
    )
    #expect(awaitedSpan.traceId == effectSpan.traceId)
    #expect(awaitedSpan.parentSpanId == effectSpan.spanId)
    #expect(childTaskSpan.traceId == effectSpan.traceId)
    #expect(childTaskSpan.parentSpanId == effectSpan.spanId)
  }

  @Test("detached tasks require explicit dependency injection and do not inherit span context")
  func detachedTaskContextBoundary() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())

    try await withDependencies {
      $0.composableOTel = client
    } operation: {
      try await client.withEffectTrace(
        effect: "propagation",
        longLived: false,
        parentContext: nil
      ) {
        _ = await Task.detached {
          await withDependencies {
            $0.composableOTel = client
          } operation: {
            await tracedCall(dependency: "detached", operation: "load") { 1 }
          }
        }.value
      }
    }
    collectors.forceFlush()

    let effectSpan = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first
    )
    let detachedSpan = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.dependency).first
    )
    #expect(detachedSpan.traceId != effectSpan.traceId)
    #expect(detachedSpan.parentSpanId != effectSpan.spanId)
  }

  @Test("effect tracing records and rethrows failures")
  func errorRethrow() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())
    do {
      let _: Void = try await client.withEffectTrace(
        effect: "failure",
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

    let span = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first
    )
    #expect(span.status.isError)
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("error"))
    #expect(span.events.map(\.name) == [ComposableOTelSemantics.Events.exception])
  }

  @Test("effect tracing records and rethrows cancellation")
  func cancellationRethrow() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())
    let task = Task {
      try await client.withEffectTrace(
        effect: "cancellation",
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
      Issue.record("Expected cancellation")
    } catch is CancellationError {
    }
    collectors.forceFlush()

    let span = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first
    )
    #expect(span.status == .unset)
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("cancelled"))
    #expect(span.attributes[TCAAttributes.effectCancelled] == .bool(true))
    #expect(span.events.map(\.name) == [ComposableOTelSemantics.Events.effectCancelled])
  }

  @Test("handled or translated cancellation follows the operation result")
  func handledCancellation() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())
    let recoveredTask = Task {
      try await client.withEffectTrace(
        effect: "recovered-cancellation",
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
        effect: "translated-cancellation",
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
      Issue.record("Expected translated cancellation")
    } catch let error as ExpectedError {
      #expect(error == .failed)
    }
    collectors.forceFlush()

    let spans = collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect)
    let recovered = try #require(
      spans.first {
        $0.attributes[TCAAttributes.effectName] == .string("recovered-cancellation")
      }
    )
    let translated = try #require(
      spans.first {
        $0.attributes[TCAAttributes.effectName] == .string("translated-cancellation")
      }
    )
    #expect(recovered.attributes[TCAAttributes.effectOutcome] == .string("success"))
    #expect(recovered.status == .ok)
    #expect(translated.attributes[TCAAttributes.effectOutcome] == .string("error"))
    #expect(translated.status.isError)
  }

  @Test("long-lived effects use one span and classify normal completion")
  @MainActor
  func longLivedCompletion() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())
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

    let spans = collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect)
    let span = try #require(spans.first)
    #expect(spans.count == 1)
    #expect(span.status == .ok)
    #expect(span.attributes[TCAAttributes.effectLongLived] == .bool(true))
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("success"))
    #expect(span.events.map(\.name) == [ComposableOTelSemantics.Events.effectCompleted])
  }

  @Test("long-lived cancellation is not completion")
  @MainActor
  func longLivedCancellation() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())
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
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first
    )
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("cancelled"))
    #expect(span.events.map(\.name) == [ComposableOTelSemantics.Events.effectCancelled])
  }

  @Test("long-lived failures emit one error terminal outcome")
  func longLivedError() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, collectors) = try TelemetryClient.test(
      metricReader: metricReader,
      policy: testPolicy()
    )
    do {
      let _: Void = try await client.withEffectTrace(
        effect: "long-lived-success",
        longLived: true,
        parentContext: nil
      ) {
        throw ExpectedError.failed
      }
      Issue.record("Expected error")
    } catch is ExpectedError {
    }
    collectors.forceFlush()

    let span = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first
    )
    #expect(span.attributes[TCAAttributes.effectLongLived] == .bool(true))
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("error"))
    #expect(span.events.map(\.name) == [ComposableOTelSemantics.Events.exception])
    #expect(
      sumLongPoints(named: ComposableOTelSemantics.Metrics.effectsErrored, in: metricReader.metrics)
        == 1
    )
    #expect(
      longPoints(named: ComposableOTelSemantics.Metrics.activeEffects, in: metricReader.metrics)
        .allSatisfy { $0.value == 0 }
    )
  }

  @Test("traceStart marker is parented to the reducer span")
  @MainActor
  func traceStartParentage() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())
    let store = TestStore(initialState: MarkerFeature.State()) {
      MarkerFeature()
    } withDependencies: {
      $0.composableOTel = client
    }

    await store.send(.start)
    await store.finish()
    collectors.forceFlush()

    let reducerSpan = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.reducer).first
    )
    let markerSpan = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first {
        $0.attributes[TCAAttributes.effectMarker] == .bool(true)
      }
    )
    #expect(markerSpan.traceId == reducerSpan.traceId)
    #expect(markerSpan.parentSpanId == reducerSpan.spanId)
    #expect(markerSpan.attributes[TCAAttributes.effectLongLived] == .bool(false))
  }

  @Test("catch-to-action is opt-in and records the observed successful completion")
  @MainActor
  func catchToActionYieldsSuccess() async throws {
    let (client, collectors) = try TelemetryClient.test(policy: testPolicy())
    let store = TestStore(initialState: CatchFeature.State()) {
      CatchFeature()
    } withDependencies: {
      $0.composableOTel = client
    }

    await store.send(.start)
    await store.receive(.errorHandled) { $0.handled = true }
    await store.finish()
    collectors.forceFlush()

    let span = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first
    )
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("success"))
    #expect(span.status == .ok)
    #expect(span.events.map(\.name) == [ComposableOTelSemantics.Events.effectCompleted])
  }

  @Test("effect counters and active accounting are balanced exactly once")
  func balancedEffectMetrics() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, _) = try TelemetryClient.test(
      metricReader: metricReader,
      policy: testPolicy()
    )

    try await client.withEffectTrace(
      effect: "success",
      longLived: false,
      parentContext: nil
    ) {}
    try await client.withEffectTrace(
      effect: "long-lived-success",
      longLived: true,
      parentContext: nil
    ) {}
    do {
      let _: Void = try await client.withEffectTrace(
        effect: "error",
        longLived: false,
        parentContext: nil
      ) {
        throw ExpectedError.failed
      }
    } catch is ExpectedError {
    }

    let cancelledTask = Task {
      try await client.withEffectTrace(
        effect: "cancelled",
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
    #expect(
      sumLongPoints(named: ComposableOTelSemantics.Metrics.effectsStarted, in: metrics) == 4
    )
    #expect(
      sumLongPoints(named: ComposableOTelSemantics.Metrics.effectsCompleted, in: metrics) == 2
    )
    #expect(
      sumLongPoints(named: ComposableOTelSemantics.Metrics.effectsCancelled, in: metrics) == 1
    )
    #expect(
      sumLongPoints(named: ComposableOTelSemantics.Metrics.effectsErrored, in: metrics) == 1
    )
    let activePoints = longPoints(
      named: ComposableOTelSemantics.Metrics.activeEffects,
      in: metrics
    )
    #expect(activePoints.count == 4)
    #expect(activePoints.allSatisfy { $0.value == 0 })
  }

  @Test("test clients retain isolated cached loggers under concurrency")
  func injectedLoggerIsolation() async throws {
    let policy = testPolicy(
      signals: .init(tracesEnabled: false, metricsEnabled: false, logsEnabled: true)
    )
    let (firstClient, firstCollectors) = try TelemetryClient.test(policy: policy)
    let (secondClient, secondCollectors) = try TelemetryClient.test(policy: policy)

    firstClient.recordNavigation(.push, route: "settings")
    secondClient.recordNavigation(.push, route: "settings")
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<64 {
        group.addTask {
          firstClient.recordNavigation(.push, route: "settings")
        }
      }
    }
    #expect(firstCollectors.logs.allRecords.count == 65)
    #expect(secondCollectors.logs.allRecords.count == 1)
  }

  @Test("bootstrap is atomic, idempotent, and unaffected by prior default-client access")
  func concurrentBootstrap() async throws {
    TelemetryBootstrap.resetForTesting()
    defer { TelemetryBootstrap.resetForTesting() }
    let defaultClient = currentTelemetryClient()
    let globalTracerProvider = ObjectIdentifier(OpenTelemetry.instance.tracerProvider as AnyObject)
    let globalMeterProvider = ObjectIdentifier(OpenTelemetry.instance.meterProvider as AnyObject)
    let globalLoggerProvider = ObjectIdentifier(OpenTelemetry.instance.loggerProvider as AnyObject)
    let clients = await withTaskGroup(
      of: TelemetryClient.self,
      returning: [TelemetryClient].self
    ) { group in
      for index in 0..<32 {
        group.addTask {
          try! TelemetryBootstrap.configure(
            serviceName: ServiceID(validating: "bootstrap-\(index)")!,
            policy: testPolicy()
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
    let repeated = try TelemetryBootstrap.configure(
      serviceName: "metadata-test",
      policy: testPolicy()
    )
    #expect(repeated.metrics === first.metrics)
    #expect(
      ObjectIdentifier(OpenTelemetry.instance.tracerProvider as AnyObject) == globalTracerProvider
    )
    #expect(
      ObjectIdentifier(OpenTelemetry.instance.meterProvider as AnyObject) == globalMeterProvider
    )
    #expect(
      ObjectIdentifier(OpenTelemetry.instance.loggerProvider as AnyObject) == globalLoggerProvider
    )
  }

  @Test("bootstrap observers receive only sanitized values and share provider lifecycle")
  func bootstrapObservers() throws {
    TelemetryBootstrap.resetForTesting()
    defer { TelemetryBootstrap.resetForTesting() }
    let spanExporter = ObserverSpanExporter()
    let logExporter = ObserverLogRecordExporter()
    let metricExporter = ObserverMetricExporter()
    let privateRoute = try #require(RouteID(validating: "private-route"))
    let client = try TelemetryBootstrap.configure(
      serviceName: "test-suite",
      policy: testPolicy(
        signals: .init(tracesEnabled: true, metricsEnabled: true, logsEnabled: true)
      ),
      observerExporters: .init(
        spanExporters: [spanExporter],
        logRecordExporters: [logExporter],
        metricExporters: [metricExporter]
      )
    )

    client.recordNavigation(.push, route: privateRoute)
    TelemetryBootstrap.forceFlushForTesting()

    let span = try #require(
      spanExporter.spans.first { $0.name == ComposableOTelSemantics.Spans.navigation }
    )
    #expect(span.attributes[TCAAttributes.navigationRoute] == .string("other"))
    let log = try #require(logExporter.records.first)
    #expect(log.attributes[TCAAttributes.navigationRoute] == .string("other"))
    let metric = try #require(
      metricExporter.metrics.first {
        $0.name == ComposableOTelSemantics.Metrics.navigationTransitions
      }
    )
    #expect(metric.data.points.first?.attributes[TCAAttributes.navigationRoute] == .string("other"))

    TelemetryBootstrap.resetForTesting()
    #expect(spanExporter.shutdownCount == 1)
    #expect(logExporter.shutdownCount == 1)
    #expect(metricExporter.shutdownCount == 1)
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
