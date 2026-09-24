import ComposableArchitecture
import ComposableOTelTesting
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

private let lifecycleSecret = "lifecycle-secret-7d1e"

private struct LifecycleSecretError: Error, CustomStringConvertible {
  var description: String { lifecycleSecret }
}

private let lifecycleSignals = TelemetrySignalConfiguration(
  tracesEnabled: true,
  metricsEnabled: true,
  logsEnabled: true
)

private let allowedLogAttributeKeys: Set<String> = [
  TCAAttributes.featureName,
  TCAAttributes.actionName,
  TCAAttributes.stateChanged,
  TCAAttributes.reducerDurationMs,
  TCAAttributes.effectName,
  TCAAttributes.effectLongLived,
  TCAAttributes.effectOutcome,
  TCAAttributes.effectDurationMs,
  TCAAttributes.effectCancelled,
  TCAAttributes.dependencyName,
  TCAAttributes.operationName,
  TCAAttributes.dependencyOutcome,
  TCAAttributes.dependencyDurationMs,
  TCAAttributes.dependencyCancelled,
  TCAAttributes.flowRoot,
  TCAAttributes.errorType,
  TCAAttributes.errorCategory,
  TCAAttributes.errorCode,
  TCAAttributes.errorHandled,
  TCAAttributes.errorRetryable,
  TCAAttributes.navigationOperation,
  TCAAttributes.navigationRoute,
  TCAAttributes.processSessionID,
  TCAAttributes.hostPlatform,
  TCAAttributes.hostProcessKind,
]

private struct PlansClient: Sendable {
  var fetchPlan: @Sendable (Int) async throws -> String
  var savePlan: @Sendable (String, Bool) async throws -> Void
  var planUpdates: @Sendable () -> AsyncThrowingStream<Int, any Error>
  var counts: @Sendable () -> AsyncStream<Int>
}

@Reducer
private struct PropagationFeature {
  struct State: Equatable {
    var loaded = false
  }

  enum Action: Equatable {
    case load
    case loaded
    case detachedRoot
    case untracked
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .load:
        return .tracedRun(effect: "load-plans") { send in
          _ = try await tracedCall(dependency: "test-dependency", operation: .fetch) {
            @Dependency(\.composableOTel) var telemetry
            telemetry.recordNavigation(.push, route: "settings")
            return 1
          }
          await send(.loaded)
        }
      case .loaded:
        state.loaded = true
        return .none
      case .detachedRoot:
        return .tracedRootRun(feature: "counter", effect: "root-flow") { _ in
          _ = await tracedCall(dependency: "cache", operation: .sync) { 1 }
        }
      case .untracked:
        return .tracedRun(effect: "success") { _ in
          _ = await tracedCall(dependency: "cache", operation: .fetch) { 1 }
        }
      }
    }
    .selectivelyInstrumented(feature: "counter") { action in
      switch action {
      case .load: "fetch-and-set"
      case .loaded: "set-count"
      case .detachedRoot: "submit"
      case .untracked: nil
      }
    }
  }
}

@Suite("Lifecycle signals")
struct LifecycleSignalsTests {
  @Test("effect success emits started and completed logs correlated to the effect span")
  func effectSuccess() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, collectors) = try TelemetryClient.test(
      metricReader: metricReader,
      policy: testPolicy(signals: lifecycleSignals)
    )
    try await client.withEffectTrace(effect: "success", longLived: false, parentContext: nil) {}
    collectors.forceFlush()

    let span = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first
    )
    let records = collectors.logs.capturedRecords
    #expect(
      records.map(\.eventName) == [
        ComposableOTelSemantics.LogEvents.effectStarted,
        ComposableOTelSemantics.LogEvents.effectCompleted,
      ]
    )
    #expect(
      records.map(\.body) == [
        ComposableOTelSemantics.LogBodies.effectStarted,
        ComposableOTelSemantics.LogBodies.effectCompleted,
      ]
    )
    #expect(records.allSatisfy { $0.traceID == span.traceId.hexString })
    #expect(records.allSatisfy { $0.spanID == span.spanId.hexString })

    let completed = try #require(collectors.logs.allRecords.last)
    #expect(completed.attributes[TCAAttributes.effectName] == .string("success"))
    #expect(completed.attributes[TCAAttributes.effectOutcome] == .string("success"))
    #expect(completed.attributes[TCAAttributes.effectCancelled] == .bool(false))
    #expect(completed.attributes[TCAAttributes.effectDurationMs] != nil)
    #expect(span.attributes[TCAAttributes.effectOutcome] == .string("success"))
    #expect(span.status == .ok)
    #expect(sum(ComposableOTelSemantics.Metrics.effectsStarted, in: metricReader) == 1)
    #expect(sum(ComposableOTelSemantics.Metrics.effectsCompleted, in: metricReader) == 1)
    #expect(!metricReader.metrics(named: ComposableOTelSemantics.Metrics.effectDuration).isEmpty)
  }

  @Test("effect failure emits a bounded failed log without the error description")
  func effectFailure() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, collectors) = try TelemetryClient.test(
      metricReader: metricReader,
      policy: testPolicy(signals: lifecycleSignals)
    )
    await #expect(throws: LifecycleSecretError.self) {
      try await client.withEffectTrace(effect: "error", longLived: false, parentContext: nil) {
        throw LifecycleSecretError()
      }
    }
    collectors.forceFlush()

    let failed = try #require(collectors.logs.allRecords.last)
    #expect(failed.eventName == ComposableOTelSemantics.LogEvents.effectFailed)
    #expect(failed.body == .string(ComposableOTelSemantics.LogBodies.effectFailed))
    #expect(failed.severity == .error)
    #expect(failed.attributes[TCAAttributes.effectOutcome] == .string("error"))
    #expect(failed.attributes[TCAAttributes.errorType] == .string("test-error"))
    #expect(try !encoded(collectors.logs.allRecords).contains(lifecycleSecret))
    #expect(try !encoded(collectors.spans.spans).contains(lifecycleSecret))
    #expect(sum(ComposableOTelSemantics.Metrics.effectsErrored, in: metricReader) == 1)
  }

  @Test("effect cancellation emits a cancelled log and counter, not an error")
  func effectCancellation() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, collectors) = try TelemetryClient.test(
      metricReader: metricReader,
      policy: testPolicy(signals: lifecycleSignals)
    )
    let task = Task {
      try await client.withEffectTrace(effect: "cancelled", longLived: false, parentContext: nil) {
        try await Task.sleep(for: .seconds(30))
      }
    }
    await Task.yield()
    task.cancel()
    _ = await task.result
    collectors.forceFlush()

    let cancelled = try #require(collectors.logs.allRecords.last)
    #expect(cancelled.eventName == ComposableOTelSemantics.LogEvents.effectCancelled)
    #expect(cancelled.body == .string(ComposableOTelSemantics.LogBodies.effectCancelled))
    #expect(cancelled.severity == .info)
    #expect(cancelled.attributes[TCAAttributes.effectOutcome] == .string("cancelled"))
    #expect(cancelled.attributes[TCAAttributes.effectCancelled] == .bool(true))
    #expect(sum(ComposableOTelSemantics.Metrics.effectsCancelled, in: metricReader) == 1)
    #expect(sum(ComposableOTelSemantics.Metrics.effectsErrored, in: metricReader) == 0)
  }

  @Test("dependency success, failure, and cancellation classify outcomes")
  func dependencyOutcomes() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, collectors) = try TelemetryClient.test(
      metricReader: metricReader,
      policy: testPolicy(signals: lifecycleSignals)
    )
    try await withDependencies {
      $0.composableOTel = client
    } operation: {
      _ = try await tracedCall(dependency: "test-dependency", operation: .fetch) { 1 }
      await #expect(throws: LifecycleSecretError.self) {
        try await tracedCall(dependency: "test-dependency", operation: .save) {
          throw LifecycleSecretError()
        }
      }
      let task = Task {
        try await tracedCall(dependency: "test-dependency", operation: .sync) {
          try await Task.sleep(for: .seconds(30))
        }
      }
      await Task.yield()
      task.cancel()
      _ = await task.result
    }
    collectors.forceFlush()

    let spans = collectors.spans.spans(named: ComposableOTelSemantics.Spans.dependency)
    func span(_ operation: String) throws -> SpanData {
      try #require(spans.first { $0.attributes[TCAAttributes.operationName] == .string(operation) })
    }
    #expect(try span("fetch").status == .ok)
    #expect(try span("fetch").attributes[TCAAttributes.dependencyOutcome] == .string("success"))
    #expect(try span("save").status.isError)
    #expect(try span("save").attributes[TCAAttributes.dependencyOutcome] == .string("error"))
    #expect(try span("sync").status == .unset)
    #expect(try span("sync").attributes[TCAAttributes.dependencyOutcome] == .string("cancelled"))
    #expect(try span("sync").attributes[TCAAttributes.dependencyCancelled] == .bool(true))

    let events = collectors.logs.capturedRecords.map(\.eventName)
    #expect(
      events == [
        ComposableOTelSemantics.LogEvents.dependencyStarted,
        ComposableOTelSemantics.LogEvents.dependencyCompleted,
        ComposableOTelSemantics.LogEvents.dependencyStarted,
        ComposableOTelSemantics.LogEvents.dependencyFailed,
        ComposableOTelSemantics.LogEvents.dependencyStarted,
        ComposableOTelSemantics.LogEvents.dependencyCompleted,
      ]
    )
    let cancelledLog = try #require(collectors.logs.allRecords.last)
    #expect(cancelledLog.attributes[TCAAttributes.dependencyOutcome] == .string("cancelled"))
    #expect(cancelledLog.body == .string(ComposableOTelSemantics.LogBodies.dependencyCompleted))
    #expect(sum(ComposableOTelSemantics.Metrics.dependenciesCalled, in: metricReader) == 3)
    #expect(sum(ComposableOTelSemantics.Metrics.dependenciesErrored, in: metricReader) == 1)
    #expect(try !encoded(collectors.logs.allRecords).contains(lifecycleSecret))
  }

  @Test("reducer trace context and feature propagate into effects, dependencies, and navigation")
  @MainActor
  func reducerPropagation() async throws {
    let (client, collectors) = try TelemetryClient.test(
      policy: testPolicy(signals: lifecycleSignals)
    )
    let store = TestStore(initialState: PropagationFeature.State()) {
      PropagationFeature()
    } withDependencies: {
      $0.composableOTel = client
    }
    await store.send(.load)
    await store.receive(.loaded) { $0.loaded = true }
    collectors.forceFlush()

    let reducer = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.reducer).first {
        $0.attributes[TCAAttributes.actionName] == .string("fetch-and-set")
      }
    )
    let effect = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first {
        $0.attributes[TCAAttributes.effectMarker] == nil
      }
    )
    let dependency = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.dependency).first
    )
    let navigation = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.navigation).first
    )
    #expect(effect.traceId == reducer.traceId)
    #expect(dependency.parentSpanId == effect.spanId)
    #expect(navigation.parentSpanId == dependency.spanId)
    for span in [effect, dependency, navigation] {
      #expect(span.traceId == reducer.traceId)
      #expect(span.attributes[TCAAttributes.featureName] == .string("counter"))
    }

    let records = collectors.logs.capturedRecords
    let dispatched = try #require(
      records.first { $0.eventName == ComposableOTelSemantics.LogEvents.actionDispatched }
    )
    #expect(dispatched.body == ComposableOTelSemantics.LogBodies.actionDispatched)
    #expect(dispatched.spanID == reducer.spanId.hexString)
    let dependencyLog = try #require(
      records.first { $0.eventName == ComposableOTelSemantics.LogEvents.dependencyCompleted }
    )
    #expect(dependencyLog.traceID == reducer.traceId.hexString)
    #expect(dependencyLog.spanID == dependency.spanId.hexString)
    let navigationLog = try #require(
      records.first { $0.eventName == ComposableOTelSemantics.LogEvents.navigationChanged }
    )
    #expect(navigationLog.spanID == navigation.spanId.hexString)
    let dependencyRecord = try #require(
      collectors.logs.allRecords.first {
        $0.eventName == ComposableOTelSemantics.LogEvents.dependencyCompleted
      }
    )
    #expect(dependencyRecord.attributes[TCAAttributes.featureName] == .string("counter"))
    #expect(Set(records.compactMap(\.traceID)) == [reducer.traceId.hexString])
  }

  @Test("tracedRootRun starts a new trace that still carries the feature")
  @MainActor
  func reducerRootRun() async throws {
    let (client, collectors) = try TelemetryClient.test(
      policy: testPolicy(signals: lifecycleSignals)
    )
    let store = TestStore(initialState: PropagationFeature.State()) {
      PropagationFeature()
    } withDependencies: {
      $0.composableOTel = client
    }
    await store.send(.detachedRoot)
    await store.finish()
    collectors.forceFlush()

    let reducer = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.reducer).first
    )
    let root = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect).first {
        $0.attributes[TCAAttributes.flowRoot] == .bool(true)
      }
    )
    let dependency = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.dependency).first
    )
    #expect(root.traceId != reducer.traceId)
    #expect(root.parentSpanId == nil || root.parentSpanId?.isValid == false)
    #expect(root.attributes[TCAAttributes.featureName] == .string("counter"))
    #expect(dependency.parentSpanId == root.spanId)
    #expect(dependency.attributes[TCAAttributes.featureName] == .string("counter"))
  }

  @Test("explicit root flows have no parent and parent their children")
  func explicitRootFlow() async throws {
    let (client, collectors) = try TelemetryClient.test(
      policy: testPolicy(signals: lifecycleSignals)
    )
    let value = try await withDependencies {
      $0.composableOTel = client
    } operation: {
      try await withTracedRootFlow(feature: "counter", flow: "root-flow") {
        try await tracedCall(dependency: "cache", operation: .fetch) { 7 }
      }
    }
    let nonthrowing = await withDependencies {
      $0.composableOTel = client
    } operation: {
      await withTracedRootFlow(feature: "counter", flow: "root-flow") { 3 }
    }
    #expect(value == 7)
    #expect(nonthrowing == 3)
    collectors.forceFlush()

    let roots = collectors.spans.spans(named: ComposableOTelSemantics.Spans.effect)
    #expect(roots.count == 2)
    #expect(roots.allSatisfy { $0.attributes[TCAAttributes.flowRoot] == .bool(true) })
    #expect(roots.allSatisfy { $0.parentSpanId == nil || $0.parentSpanId?.isValid == false })
    #expect(Set(roots.map(\.traceId)).count == 2)
    let dependency = try #require(
      collectors.spans.spans(named: ComposableOTelSemantics.Spans.dependency).first
    )
    let root = try #require(roots.first { $0.traceId == dependency.traceId })
    #expect(dependency.parentSpanId == root.spanId)
    #expect(dependency.attributes[TCAAttributes.featureName] == .string("counter"))
    let startedLog = try #require(collectors.logs.allRecords.first)
    #expect(startedLog.eventName == ComposableOTelSemantics.LogEvents.effectStarted)
    #expect(startedLog.attributes[TCAAttributes.flowRoot] == .bool(true))
  }

  @Test("suppressed reducer actions keep effects and dependencies silent")
  @MainActor
  func suppressedActions() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, collectors) = try TelemetryClient.test(
      metricReader: metricReader,
      policy: testPolicy(signals: lifecycleSignals)
    )
    let store = TestStore(initialState: PropagationFeature.State()) {
      PropagationFeature()
    } withDependencies: {
      $0.composableOTel = client
    }
    await store.send(.untracked)
    await store.finish()
    collectors.forceFlush()

    #expect(collectors.spans.spans.isEmpty)
    #expect(collectors.logs.allRecords.isEmpty)
    #expect(sum(ComposableOTelSemantics.Metrics.dependenciesCalled, in: metricReader) == 0)
  }

  @Test("an instrumented dependency client traces every endpoint consistently")
  func instrumentedClient() async throws {
    let (client, collectors) = try TelemetryClient.test(
      policy: testPolicy(signals: lifecycleSignals)
    )
    let telemetry = TelemetryDependencyInstrumentation("test-dependency")
    let base = PlansClient(
      fetchPlan: { id in "plan-\(id)-\(lifecycleSecret)" },
      savePlan: { _, shouldFail in
        if shouldFail { throw LifecycleSecretError() }
      },
      planUpdates: {
        AsyncThrowingStream { continuation in
          continuation.yield(1)
          continuation.yield(2)
          continuation.finish()
        }
      },
      counts: {
        AsyncStream { continuation in
          continuation.yield(1)
          continuation.finish()
        }
      }
    )
    let plans = PlansClient(
      fetchPlan: telemetry.instrument(.fetch, base.fetchPlan),
      savePlan: telemetry.instrument(.save, base.savePlan),
      planUpdates: telemetry.instrumentStream(.stream, base.planUpdates),
      counts: telemetry.instrumentStream(.sync, base.counts)
    )

    try await withDependencies {
      $0.composableOTel = client
    } operation: {
      let plan = try await plans.fetchPlan(4)
      #expect(plan.hasPrefix("plan-4"))
      try await plans.savePlan("draft", false)
      await #expect(throws: LifecycleSecretError.self) {
        try await plans.savePlan(lifecycleSecret, true)
      }
      var updates: [Int] = []
      for try await update in plans.planUpdates() {
        updates.append(update)
      }
      #expect(updates == [1, 2])
      var counts: [Int] = []
      for await count in plans.counts() {
        counts.append(count)
      }
      #expect(counts == [1])
      let direct = try await telemetry.call(.authorize) { true }
      #expect(direct)
    }
    collectors.forceFlush()

    let spans = collectors.spans.spans(named: ComposableOTelSemantics.Spans.dependency)
    #expect(
      spans.map { $0.attributes[TCAAttributes.operationName] }.compactMap { value -> String? in
        guard case .string(let name) = value else { return nil }
        return name
      }.sorted() == ["authorize", "fetch", "save", "save", "stream", "sync"]
    )
    #expect(
      spans.allSatisfy { $0.attributes[TCAAttributes.dependencyName] == .string("test-dependency") }
    )
    let stream = try #require(
      spans.first { $0.attributes[TCAAttributes.operationName] == .string("stream") }
    )
    #expect(stream.attributes[TCAAttributes.dependencyOutcome] == .string("success"))
    #expect(try !encoded(collectors.spans.spans).contains(lifecycleSecret))
    #expect(try !encoded(collectors.logs.allRecords).contains(lifecycleSecret))
    #expect(try !encoded(collectors.spans.spans).contains("draft"))
  }

  @Test("instrumented streams classify upstream failure and consumer cancellation")
  func instrumentedStreamTermination() async throws {
    let (client, collectors) = try TelemetryClient.test(
      policy: testPolicy(signals: lifecycleSignals)
    )
    let telemetry = TelemetryDependencyInstrumentation("test-dependency")
    let failing = telemetry.instrumentStream(.stream) { () -> AsyncThrowingStream<Int, any Error> in
      AsyncThrowingStream { continuation in
        continuation.yield(1)
        continuation.finish(throwing: LifecycleSecretError())
      }
    }
    let endless = telemetry.instrumentStream(.sync) { () -> AsyncStream<Int> in
      AsyncStream { continuation in
        continuation.yield(1)
      }
    }

    await withDependencies {
      $0.composableOTel = client
    } operation: {
      await #expect(throws: LifecycleSecretError.self) {
        for try await _ in failing() {}
      }
      let consumer = Task {
        for await _ in endless() {
          break
        }
      }
      await consumer.value
    }
    try await Task.sleep(for: .milliseconds(50))
    collectors.forceFlush()

    let spans = collectors.spans.spans(named: ComposableOTelSemantics.Spans.dependency)
    let failed = try #require(
      spans.first { $0.attributes[TCAAttributes.operationName] == .string("stream") }
    )
    #expect(failed.attributes[TCAAttributes.dependencyOutcome] == .string("error"))
    #expect(failed.status.isError)
    let cancelled = try #require(
      spans.first { $0.attributes[TCAAttributes.operationName] == .string("sync") }
    )
    #expect(cancelled.attributes[TCAAttributes.dependencyOutcome] == .string("cancelled"))
    #expect(try !encoded(collectors.logs.allRecords).contains(lifecycleSecret))
  }

  @Test("lifecycle logs export only bounded attributes and metrics keep their dimensions")
  @MainActor
  func attributeBounds() async throws {
    let metricReader = InMemoryMetricReader()
    let (client, collectors) = try TelemetryClient.test(
      metricReader: metricReader,
      policy: testPolicy(signals: lifecycleSignals)
    )
    let store = TestStore(initialState: PropagationFeature.State()) {
      PropagationFeature()
    } withDependencies: {
      $0.composableOTel = client
    }
    await store.send(.load)
    await store.receive(.loaded) { $0.loaded = true }
    try await withDependencies {
      $0.composableOTel = client
    } operation: {
      _ = try await tracedCall(dependency: "not-registered", operation: "not-registered") {
        lifecycleSecret
      }
    }
    collectors.forceFlush()

    let records = collectors.logs.allRecords
    #expect(!records.isEmpty)
    for record in records {
      #expect(record.eventName.map(ComposableOTelSemantics.LogEvents.all.contains) == true)
      guard case .string(let body) = record.body else {
        Issue.record("Expected a string body")
        continue
      }
      #expect(ComposableOTelSemantics.LogBodies.all.contains(body))
      #expect(Set(record.attributes.keys).isSubset(of: allowedLogAttributeKeys))
    }
    #expect(try !encoded(records).contains(lifecycleSecret))
    #expect(try !encoded(records).contains("not-registered"))

    for metric in metricReader.metrics {
      let allowed = ComposableOTelSemantics.Metrics.attributeKeys(for: metric.name)
      for point in metric.data.points {
        #expect(Set(point.attributes.keys).isSubset(of: allowed))
        #expect(
          point.attributes[TCAAttributes.featureName] == nil
            || allowed.contains(TCAAttributes.featureName)
        )
      }
    }
  }

  @Test("fractional log sampling decides per record and spreads across event names")
  func perRecordSampling() throws {
    let half = try #require(TelemetryLogSamplingRate(0.5))
    let logging = TelemetryLoggingConfiguration(infoSampling: half)
    let session = TelemetryProcessSessionID.current
    for eventName in ComposableOTelSemantics.LogEvents.all {
      let decisions = (0..<200).map {
        logging.shouldRecord(
          severity: .info,
          processSessionID: session,
          eventName: eventName,
          spanID: nil,
          sequence: UInt64($0)
        )
      }
      #expect(decisions.contains(true))
      #expect(decisions.contains(false))
    }
    #expect(logging.passesSeverityFilter(.info))
    #expect(!TelemetryLoggingConfiguration(minimumSeverity: .error).passesSeverityFilter(.info))
  }
}

private func sum(_ name: String, in reader: InMemoryMetricReader) -> Int {
  reader.metrics(named: name).flatMap(\.data.points).reduce(0) { total, point in
    total + ((point as? LongPointData)?.value ?? 0)
  }
}

private func encoded<T: Encodable>(_ value: T) throws -> String {
  String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}
