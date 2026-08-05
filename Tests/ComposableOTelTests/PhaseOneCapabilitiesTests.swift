import ComposableArchitecture
import ComposableOTelTesting
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

private enum PhaseOneFailure: Error {
  case failed
}

@Reducer
private struct HostContextFeature {
  struct State: Equatable {}
  enum Action: Equatable {
    case start
  }

  var body: some ReducerOf<Self> {
    Reduce { _, action in
      switch action {
      case .start:
        return .tracedRun(effect: "propagation") { _ in
          @Dependency(\.composableOTel) var telemetry
          #expect(telemetry.log(.info, "Session breadcrumb") == .recorded)
          _ = await tracedCall(dependency: "awaited", operation: "load") { 1 }
        }
      }
    }
    .instrumented(feature: "counter", action: { _ in "fetch-and-set" })
  }
}

@Reducer
private struct SelectiveFeature {
  struct State: Equatable {
    var selectedCount = 0
  }

  enum Action: Equatable {
    case noisy
    case noisySendingSelected
    case selected
    case selectedFollowUp
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .noisy:
        return .tracedRun(effect: "success") { _ in
          _ = await tracedCall(dependency: "cache", operation: "load") { 1 }
        }
      case .noisySendingSelected:
        return .tracedRun(effect: "success") { send in
          _ = await tracedCall(dependency: "cache", operation: "load") { 1 }
          await send(.selectedFollowUp)
          _ = await tracedCall(dependency: "cache", operation: "load") { 2 }
        }
      case .selected:
        state.selectedCount += 1
        return .none
      case .selectedFollowUp:
        state.selectedCount += 1
        return .tracedRun(effect: "success") { _ in
          _ = await tracedCall(dependency: "cache", operation: "load") { 3 }
        }
      }
    }
    .selectivelyInstrumented(
      feature: "counter",
      action: {
        switch $0 {
        case .noisy, .noisySendingSelected: nil
        case .selected, .selectedFollowUp: "increment"
        }
      }
    )
  }
}

@Suite("Phase 1 core capabilities", .serialized)
struct PhaseOneCapabilitiesTests {
  @Suite("Registered host context")
  struct HostContextTests {
    @Test("propagates through effect and dependency spans and logs but never metrics")
    @MainActor
    func crossSignalPropagationAndMetricExclusion() async throws {
      struct RegisteredCounterPayload: Sendable {
        let succeeded: Bool
      }
      let session = TelemetryProcessSessionID(
        UUID(uuidString: "c50c7f17-8cd6-4bcb-932e-a0571f382c86")!
      )
      let hostContext = TelemetryHostContext(
        processSessionID: session,
        platform: .macOS,
        processKind: .test
      )
      let signals = TelemetrySignalConfiguration(
        tracesEnabled: true,
        metricsEnabled: true,
        logsEnabled: true
      )
      let registeredCounter = try TelemetryCounterDefinition<RegisteredCounterPayload>(
        name: .init("test.session-exclusion"),
        unit: .init("{event}"),
        description: .init("session-exclusion"),
        maximumSeries: 2,
        fields: [
          .boolean(.init("test.succeeded")) { $0.succeeded }
        ]
      )
      let catalog = try TelemetryContractCatalog(
        contractVersion: .init(1),
        counters: [.init(registeredCounter)]
      )
      let policy = TelemetryPolicy(
        schema: testSchema,
        catalog: catalog,
        signals: signals,
        hostContext: hostContext
      )
      let metricReader = InMemoryMetricReader()
      let contractMetricReader = InMemoryMetricReader(temporality: .delta)
      let (client, collectors) = try TelemetryClient.test(
        metricReader: metricReader,
        contractMetricReader: contractMetricReader,
        policy: policy
      )

      let store = TestStore(initialState: HostContextFeature.State()) {
        HostContextFeature()
      } withDependencies: {
        $0.composableOTel = client
      }
      await store.send(.start)
      await store.finish()
      try client.add(
        registeredCounter,
        delta: .init(1),
        payload: .init(succeeded: true)
      )
      collectors.forceFlush()

      collectors.spans.assertSpanTrees(
        exactly: [
          .init(
            ComposableOTelSemantics.Spans.reducer,
            children: [
              .init(
                ComposableOTelSemantics.Spans.effect,
                children: [.init(ComposableOTelSemantics.Spans.dependency)]
              )
            ]
          )
        ]
      )
      #expect(collectors.spans.capturedSpans.count == 3)
      #expect(collectors.spans.capturedSpans.allSatisfy { $0.hostContext == hostContext.captured })
      let log = try #require(
        collectors.logs.capturedRecords.first {
          $0.eventName == TelemetryLogWireFormat.eventName
        }
      )
      #expect(log.hostContext == hostContext.captured)
      #expect(log.traceID == collectors.spans.spanTrees.first?.span.traceID)
      #expect(!metricReader.metrics.isEmpty)
      #expect(metricReader.containsHostContext == false)
      #expect(!contractMetricReader.metrics.isEmpty)
      #expect(contractMetricReader.containsHostContext == false)
      metricReader.assertHostContextExcluded()
      contractMetricReader.assertHostContextExcluded()
    }

    @Test("drops forged context and rejects contract collisions")
    func malformedAndUnregisteredValuesFailClosed() throws {
      let collector = InMemorySpanCollector()
      let policy = testPolicy()
      let exporter = PrivacyPreservingSpanExporter(exporter: collector, policy: policy)
      let provider = TracerProviderBuilder()
        .add(spanProcessor: SimpleSpanProcessor(spanExporter: exporter))
        .build()
      let tracer = provider.get(
        instrumentationName: ComposableOTelMetadata.instrumentationName,
        instrumentationVersion: ComposableOTelMetadata.version
      )
      let span = tracer.spanBuilder(spanName: ComposableOTelSemantics.Spans.effect)
        .setAttributes([
          TCAAttributes.effectName: .string("success"),
          TCAAttributes.processSessionID: .string("not-a-uuid"),
          TCAAttributes.hostPlatform: .string("linux"),
          TCAAttributes.hostProcessKind: .string("unknown"),
        ])
        .startSpan()
      span.end()
      provider.forceFlush()

      let exported = try #require(collector.spans.first)
      #expect(exported.attributes[TCAAttributes.processSessionID] == nil)
      #expect(exported.attributes[TCAAttributes.hostPlatform] == nil)
      #expect(exported.attributes[TCAAttributes.hostProcessKind] == nil)
      #expect(TelemetryProcessSessionID(validating: "NOT-A-UUID") == nil)
      #expect(
        TelemetryProcessSessionID(
          validating: "C50C7F17-8CD6-4BCB-932E-A0571F382C86"
        ) == nil
      )

      #expect(throws: TelemetryContractError.invalidDefinition) {
        _ = try TelemetrySpanDefinition<Void>(
          name: .init("host.collision"),
          fields: [
            try .string(.init(TCAAttributes.processSessionID)) { _ in
              try? TelemetryStringValue("forged")
            }
          ]
        )
      }
    }
  }

  @Suite("Selective reducer instrumentation")
  struct SelectiveReducerTests {
    @Test("nil action suppresses reducer, effect, dependency, log, and metric signals")
    @MainActor
    func nilActionIsCompletelySilent() async throws {
      let metricReader = InMemoryMetricReader()
      let (client, collectors) = try TelemetryClient.test(
        metricReader: metricReader,
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: true, logsEnabled: true)
        )
      )
      let store = TestStore(initialState: SelectiveFeature.State()) {
        SelectiveFeature()
      } withDependencies: {
        $0.composableOTel = client
      }

      await store.send(.noisy)
      await store.finish()
      collectors.forceFlush()
      #expect(collectors.spans.spans.isEmpty)
      #expect(collectors.logs.allRecords.isEmpty)
      #expect(metricReader.metrics.isEmpty)

      await store.send(.selected) {
        $0.selectedCount = 1
      }
      collectors.forceFlush()
      #expect(
        collectors.spans.spans(named: ComposableOTelSemantics.Spans.reducer).count == 1
      )
    }

    @Test("selected follow-up sent by a suppressed effect emits one complete signal set")
    @MainActor
    func selectedFollowUpClearsSuppression() async throws {
      let metricReader = InMemoryMetricReader()
      let (client, collectors) = try TelemetryClient.test(
        metricReader: metricReader,
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: true, logsEnabled: true)
        )
      )
      let store = TestStore(initialState: SelectiveFeature.State()) {
        SelectiveFeature()
      } withDependencies: {
        $0.composableOTel = client
      }

      await store.send(.noisySendingSelected)
      await store.receive(.selectedFollowUp) {
        $0.selectedCount = 1
      }
      await store.finish()
      collectors.forceFlush()

      let spans = collectors.spans.spans
      #expect(spans.count == 3)
      collectors.spans.assertSpanTrees(
        exactly: [
          .init(
            ComposableOTelSemantics.Spans.reducer,
            children: [
              .init(
                ComposableOTelSemantics.Spans.effect,
                children: [.init(ComposableOTelSemantics.Spans.dependency)]
              )
            ]
          )
        ]
      )
      let reducer = try #require(
        spans.first { $0.name == ComposableOTelSemantics.Spans.reducer }
      )
      #expect(reducer.attributes[TCAAttributes.actionName] == .string("increment"))
      let actionLogs = collectors.logs.allRecords.filter {
        $0.body == .string(ComposableOTelSemantics.LogBodies.actionDispatched)
      }
      #expect(actionLogs.count == 1)
      #expect(actionLogs.first?.attributes[TCAAttributes.actionName] == .string("increment"))

      let metricNames = Set(metricReader.metrics.map(\.name))
      #expect(metricNames.contains(ComposableOTelSemantics.Metrics.actionsDispatched))
      #expect(metricNames.contains(ComposableOTelSemantics.Metrics.reducerDuration))
      #expect(metricNames.contains(ComposableOTelSemantics.Metrics.effectsStarted))
      #expect(metricNames.contains(ComposableOTelSemantics.Metrics.dependenciesCalled))
      #expect(
        phaseOneLongMetricTotal(
          ComposableOTelSemantics.Metrics.actionsDispatched,
          metrics: metricReader.metrics
        ) == 1
      )
      #expect(
        phaseOneLongMetricTotal(
          ComposableOTelSemantics.Metrics.effectsStarted,
          metrics: metricReader.metrics
        ) == 1
      )
      #expect(
        phaseOneLongMetricTotal(
          ComposableOTelSemantics.Metrics.dependenciesCalled,
          metrics: metricReader.metrics
        ) == 1
      )
    }
  }

  @Suite("Logging controls")
  struct LoggingTests {
    @Test("filters severity and deterministically samples each severity")
    func severityAndSampling() throws {
      let half = try #require(TelemetryLogSamplingRate(0.5))
      let logging = TelemetryLoggingConfiguration(
        minimumSeverity: .info,
        infoSampling: half,
        errorSampling: .always,
        deterministicSeed: 42
      )
      let policy = TelemetryPolicy(
        schema: testSchema,
        signals: .init(tracesEnabled: false, metricsEnabled: false, logsEnabled: true),
        logging: logging
      )
      let (first, firstCollectors) = try TelemetryClient.test(policy: policy)
      let (second, secondCollectors) = try TelemetryClient.test(policy: policy)

      let firstResult = first.log(.info, "Deterministic sample")
      let secondResult = second.log(.info, "Deterministic sample")
      #expect(firstResult == secondResult)
      #expect(firstCollectors.logs.allRecords.count == secondCollectors.logs.allRecords.count)
      #expect(first.log(.error, "Always retained error") == .recorded)

      let errorsOnly = TelemetryPolicy(
        schema: testSchema,
        signals: .init(tracesEnabled: false, metricsEnabled: false, logsEnabled: true),
        logging: .init(minimumSeverity: .error)
      )
      let (errorClient, errorCollectors) = try TelemetryClient.test(policy: errorsOnly)
      #expect(errorClient.log(.info, "Filtered info") == .dropped)
      #expect(errorClient.log(.error, "Retained error") == .recorded)
      errorClient.recordNavigation(.push, route: "settings")
      #expect(errorCollectors.logs.capturedRecords.map(\.severity) == [.error])
    }

    #if DEBUG
      @Test("DEBUG renderer evaluates once and leaks into no retained path")
      func debugRendererIsImmediateAndEphemeral() throws {
        let policy = testPolicy(
          signals: .init(tracesEnabled: false, metricsEnabled: false, logsEnabled: true)
        )
        let (client, collectors) = try TelemetryClient.test(policy: policy)
        let evaluation = PhaseOneEvaluationCounter()
        let rendering = PhaseOneRenderCapture()
        let sentinel = "debug-private-sentinel"

        #expect(client.log(.info, "Default \(evaluation.next(sentinel))") == .recorded)
        #expect(evaluation.count == 0)
        #expect(
          client.log(
            .info,
            "Private \(evaluation.next(sentinel))",
            debugConsole: .init { severity, body in
              rendering.append(severity: severity, body: body)
            }
          ) == .recorded
        )

        #expect(evaluation.count == 1)
        #expect(rendering.values == [.init(severity: .info, body: "Private \(sentinel)")])
        let retained = try #require(collectors.logs.privacyAwareLogs.last)
        #expect(retained.body == "Private <private>")
        #expect(!String(reflecting: collectors.logs.allRecords).contains(sentinel))
      }
    #endif
  }

  @Suite("Head and tail sampling")
  struct TailSamplingTests {
    @Test("ordinary head sampling still retains and drops whole traces")
    func normalSampling() async throws {
      let enabled = try tailConfiguration(slowThreshold: .seconds(1))
      let (headClient, headCollectors) = try TelemetryClient.test(
        samplingRatio: 1,
        tailSampling: enabled,
        policy: testPolicy()
      )
      try await headClient.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {}
      headCollectors.forceFlush()
      #expect(headCollectors.spans.spans.count == 1)

      let (droppedClient, droppedCollectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: .disabled,
        policy: testPolicy()
      )
      try await droppedClient.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {}
      droppedCollectors.forceFlush()
      #expect(droppedCollectors.spans.spans.isEmpty)
    }

    @Test("head-sampled long-lived traces and error logs bypass tail eviction and age")
    func headSampledTraceSurvivesPressure() async throws {
      let tailPolicy = try TelemetryTailSamplingPolicy(
        slowTraceThreshold: .milliseconds(50),
        maximumTraceCount: 1,
        maximumRetainedSpanCount: 4,
        maximumRetainedBreadcrumbCount: 4,
        maximumRetainedBytes: 64 * 1_024,
        maximumAge: .milliseconds(50)
      )
      let (client, collectors) = try TelemetryClient.test(
        samplingRatio: 1,
        tailSampling: .enabled(tailPolicy),
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
        )
      )
      let started = PhaseOneAsyncGate()
      let release = PhaseOneAsyncGate()
      let first = Task {
        try await client.withEffectTrace(
          effect: "long-lived-success",
          longLived: true,
          parentContext: nil
        ) {
          #expect(client.log(.error, "First head-sampled error") == .recorded)
          await started.open()
          await release.wait()
        }
      }

      await started.wait()
      #expect(collectors.logs.records(withSeverity: .error).count == 1)
      try await Task.sleep(for: .milliseconds(75))
      try await client.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {
        #expect(client.log(.error, "Second head-sampled error") == .recorded)
      }
      await release.open()
      try await first.value
      collectors.forceFlush()

      #expect(collectors.spans.spans.count == 2)
      let traceIDs = Set(collectors.spans.spans.map(\.traceId))
      let errors = collectors.logs.records(withSeverity: .error)
      #expect(errors.count == 2)
      #expect(
        errors.allSatisfy { record in
          guard let traceID = record.spanContext?.traceId else { return false }
          return traceIDs.contains(traceID)
        }
      )
    }

    @Test("error promotes the complete root tree and correlated sanitized breadcrumbs")
    func errorPromotion() async throws {
      let (client, collectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: try tailConfiguration(slowThreshold: .seconds(1)),
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
        )
      )
      let sentinel = "tail-private-sentinel"

      do {
        try await withDependencies {
          $0.composableOTel = client
        } operation: {
          try await client.withEffectTrace(
            effect: "failure",
            longLived: false,
            parentContext: nil
          ) {
            #expect(client.log(.info, "Breadcrumb \(sentinel)") == .recorded)
            let _: Int = try await tracedCall(
              dependency: "test-dependency",
              operation: "failing"
            ) {
              throw PhaseOneFailure.failed
            }
          }
        }
        Issue.record("Expected failure")
      } catch is PhaseOneFailure {
      }
      collectors.forceFlush()

      collectors.spans.assertSpanTrees(
        exactly: [
          .init(
            ComposableOTelSemantics.Spans.effect,
            children: [.init(ComposableOTelSemantics.Spans.dependency)]
          )
        ]
      )
      #expect(collectors.spans.spans.count == 2)
      #expect(collectors.logs.allRecords.count >= 3)
      #expect(collectors.logs.allRecords.allSatisfy { $0.spanContext != nil })
      #expect(!String(reflecting: collectors.logs.allRecords).contains(sentinel))
      #expect(collectors.tailSamplingState?.retainedSpanCount == 0)
      #expect(collectors.tailSamplingState?.retainedBreadcrumbCount == 0)
    }

    @Test("reviewed slow threshold and explicit trigger independently promote")
    func slowAndExplicitPromotion() async throws {
      let (slowClient, slowCollectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: try tailConfiguration(slowThreshold: .milliseconds(1)),
        policy: testPolicy()
      )
      try await slowClient.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {
        try await Task.sleep(for: .milliseconds(10))
      }
      slowCollectors.forceFlush()
      #expect(slowCollectors.spans.spans.count == 1)

      let (explicitClient, explicitCollectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: try tailConfiguration(slowThreshold: .seconds(1)),
        policy: testPolicy()
      )
      try await explicitClient.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {
        #expect(explicitClient.triggerDiagnosticTracePromotion() == .promoted)
      }
      explicitCollectors.forceFlush()
      #expect(explicitCollectors.spans.spans.count == 1)
    }

    @Test("accepted promotion delivers a later child after age and entry pressure")
    func promotedTraceRetainsLaterChildren() async throws {
      let tailPolicy = try TelemetryTailSamplingPolicy(
        slowTraceThreshold: .milliseconds(50),
        maximumTraceCount: 2,
        maximumRetainedSpanCount: 8,
        maximumRetainedBreadcrumbCount: 4,
        maximumRetainedBytes: 64 * 1_024,
        maximumAge: .milliseconds(50)
      )
      let (client, collectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: .enabled(tailPolicy),
        policy: testPolicy()
      )
      let contextCapture = PhaseOneSpanContextCapture()

      try await client.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {
        contextCapture.value = OpenTelemetry.instance.contextProvider.activeSpan?.context
        #expect(client.triggerDiagnosticTracePromotion() == .promoted)
      }
      let parentContext = try #require(contextCapture.value)
      try await Task.sleep(for: .milliseconds(75))

      for _ in 0..<4 {
        try await client.withEffectTrace(
          effect: "success",
          longLived: false,
          parentContext: nil
        ) {}
      }
      try await client.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: parentContext
      ) {}
      collectors.forceFlush()

      let promoted = collectors.spans.spans.filter { $0.traceId == parentContext.traceId }
      #expect(promoted.count == 2)
      let root = try #require(promoted.first { $0.spanId == parentContext.spanId })
      let child = try #require(promoted.first { $0.spanId != parentContext.spanId })
      #expect(child.parentSpanId == root.spanId)
    }

    @Test("registered typed spans retain their exact contract when promoted")
    func typedSpanCompatibility() async throws {
      struct Payload: Sendable {
        let retryable: Bool
      }
      let definition = try TelemetrySpanDefinition<Payload>(
        name: .init("test.promoted-contract"),
        fields: [
          .boolean(.init("test.retryable")) { $0.retryable }
        ]
      )
      let catalog = try TelemetryContractCatalog(
        contractVersion: .init(3),
        spans: [.init(definition)]
      )
      let policy = TelemetryPolicy(
        schema: testSchema,
        catalog: catalog,
        signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false)
      )
      let (client, collectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: try tailConfiguration(slowThreshold: .seconds(1)),
        policy: policy
      )

      do {
        let _: Void = try await client.withSpan(
          definition,
          payload: .init(retryable: true)
        ) {
          throw PhaseOneFailure.failed
        }
      } catch is PhaseOneFailure {
      }
      collectors.forceFlush()

      let decoded = try #require(collectors.decodedSpans(for: definition).first)
      #expect(decoded.contractVersion == 3)
      #expect(decoded.fields == ["test.retryable": .boolean(true)])
    }

    @Test("unpromoted and cancelled traces remain memory-only")
    func unpromotedAndCancellation() async throws {
      let tail = try tailConfiguration(slowThreshold: .seconds(1))
      let (client, collectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: tail,
        policy: testPolicy()
      )
      try await client.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {}

      let task = Task {
        try await client.withEffectTrace(
          effect: "cancelled",
          longLived: true,
          parentContext: nil
        ) {
          try await Task.sleep(for: .seconds(30))
        }
      }
      await Task.yield()
      task.cancel()
      _ = try? await task.value
      collectors.forceFlush()

      #expect(collectors.spans.spans.isEmpty)
      #expect(collectors.tailSamplingState?.retainedTraceCount == 2)
      #expect(collectors.tailSamplingState?.retainedSpanCount == 2)
    }

    @Test("count, byte-estimate, breadcrumb, and age bounds are enforced")
    func memoryBounds() async throws {
      #expect(throws: TelemetryTailSamplingConfigurationError.invalidLimits) {
        _ = try TelemetryTailSamplingPolicy(slowTraceThreshold: .zero)
      }
      let policy = try TelemetryTailSamplingPolicy(
        slowTraceThreshold: .milliseconds(100),
        maximumTraceCount: 2,
        maximumRetainedSpanCount: 2,
        maximumRetainedBreadcrumbCount: 2,
        maximumRetainedBytes: 64 * 1_024,
        maximumAge: .milliseconds(100)
      )
      let (client, collectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: .enabled(policy),
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
        )
      )
      for _ in 0..<3 {
        try await client.withEffectTrace(
          effect: "success",
          longLived: false,
          parentContext: nil
        ) {}
      }
      #expect(collectors.tailSamplingState?.retainedTraceCount == 2)
      #expect(collectors.tailSamplingState?.retainedSpanCount == 2)

      let (breadcrumbClient, breadcrumbCollectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: .enabled(policy),
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
        )
      )
      try await breadcrumbClient.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {
        for _ in 0..<3 {
          #expect(breadcrumbClient.log(.info, "Recent breadcrumb") == .recorded)
        }
      }
      #expect(breadcrumbCollectors.tailSamplingState?.retainedBreadcrumbCount == 2)

      try await Task.sleep(for: .milliseconds(150))
      collectors.forceFlush()
      breadcrumbCollectors.forceFlush()
      #expect(collectors.tailSamplingState?.retainedTraceCount == 0)
      #expect(breadcrumbCollectors.tailSamplingState?.retainedTraceCount == 0)

      let tiny = try TelemetryTailSamplingPolicy(
        slowTraceThreshold: .seconds(1),
        maximumTraceCount: 1,
        maximumRetainedSpanCount: 1,
        maximumRetainedBreadcrumbCount: 1,
        maximumRetainedBytes: 1,
        maximumAge: .seconds(1)
      )
      let (tinyClient, tinyCollectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: .enabled(tiny),
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
        )
      )
      do {
        let _: Void = try await tinyClient.withEffectTrace(
          effect: "failure",
          longLived: false,
          parentContext: nil
        ) {
          throw PhaseOneFailure.failed
        }
      } catch is PhaseOneFailure {
      }
      tinyCollectors.forceFlush()
      #expect(tinyCollectors.spans.spans.count == 1)
      #expect(
        tinyCollectors.logs.records(withSeverity: .error).allSatisfy {
          $0.spanContext == nil
        }
      )
      #expect(tinyCollectors.tailSamplingState?.retainedByteEstimate == 0)
    }

    @Test("one expiration task serves repeated records with the same deadline")
    func expirationSchedulingIsStable() async throws {
      let clock = PhaseOneTailClock()
      let coordinator = RuntimeTailSamplingCoordinator(
        policy: try .init(
          slowTraceThreshold: .seconds(1),
          maximumTraceCount: 2,
          maximumRetainedSpanCount: 8,
          maximumRetainedBreadcrumbCount: 32,
          maximumRetainedBytes: 64 * 1_024,
          maximumAge: .seconds(1)
        ),
        samplingRatio: 0,
        clock: clock.runtimeClock,
        emitSpans: { _ in .accepted },
        emitLog: { _ in .accepted }
      )
      let context = SpanContext.create(
        traceId: .random(),
        spanId: .random(),
        traceFlags: .init(),
        traceState: .init()
      )
      let record = ReadableLogRecord(
        resource: Resource(),
        instrumentationScopeInfo: InstrumentationScopeInfo(
          name: ComposableOTelMetadata.instrumentationName,
          version: ComposableOTelMetadata.version
        ),
        timestamp: clock.now,
        spanContext: context,
        severity: .info,
        body: .string(ComposableOTelSemantics.LogBodies.actionDispatched),
        attributes: [:]
      )

      for _ in 0..<16 {
        #expect(coordinator.record(log: record) == .accepted)
      }
      for _ in 0..<1_000 where clock.sleepCount == 0 {
        await Task.yield()
      }
      #expect(clock.sleepCount == 1)
      try await Task.sleep(for: .milliseconds(10))
      #expect(clock.sleepCount == 1)
      coordinator.shutdown(exportUncorrelatedErrors: false)
    }

    @Test("tail observers receive released signals even when the queue drops them")
    func observerDeliveryIsIndependent() throws {
      let signals = TelemetrySignalConfiguration(
        tracesEnabled: true,
        metricsEnabled: false,
        logsEnabled: true
      )
      let policy = testPolicy(signals: signals)
      let (sourceClient, sourceCollectors) = try TelemetryClient.test(policy: policy)
      sourceClient.recordNavigation(.push, route: "settings")
      sourceCollectors.forceFlush()
      let span = try #require(sourceCollectors.spans.spans.first)
      let log = try #require(sourceCollectors.logs.allRecords.first)
      let spanObserver = ObserverSpanExporter()
      let logObserver = ObserverLogRecordExporter()
      let observerPipeline = TelemetryObserverPipeline(
        exporters: .init(
          spanExporters: [spanObserver],
          logRecordExporters: [logObserver]
        ),
        policy: policy,
        preserveErrorCorrelation: true
      )
      let emitter = RuntimeTailSignalEmitter(
        offerSpans: { _ in .dropped },
        offerLog: { _ in .dropped },
        observerPipeline: observerPipeline
      )

      #expect(emitter.emit(spans: [span]) == .dropped)
      #expect(emitter.emit(log: log) == .dropped)
      #expect(spanObserver.spans.count == 1)
      #expect(logObserver.records.count == 1)
    }

    @Test("concurrent explicit promotions export each trace once")
    func concurrentPromotion() async throws {
      let (client, collectors) = try TelemetryClient.test(
        samplingRatio: 0,
        tailSampling: try tailConfiguration(slowThreshold: .seconds(1)),
        policy: testPolicy()
      )

      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<32 {
          group.addTask {
            try? await client.withEffectTrace(
              effect: "success",
              longLived: false,
              parentContext: nil
            ) {
              _ = client.triggerDiagnosticTracePromotion()
            }
          }
        }
      }
      collectors.forceFlush()

      #expect(collectors.spans.spans.count == 32)
      #expect(Set(collectors.spans.spans.map(\.traceId)).count == 32)
    }

    @Test("production runtime never queues or persists an unpromoted trace")
    func runtimeQueueAndDiscardLifecycle() async throws {
      let capture = InMemoryEncodedRequestCollector()
      var configuration = TelemetryRuntime.Configuration(
        serviceName: "test-suite",
        endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
        samplingRatio: 0,
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false)
        ),
        traces: .init(
          maximumQueueSize: 128,
          maximumBatchSize: 4,
          scheduledDelay: .seconds(60)
        ),
        logs: .init(scheduledDelay: .seconds(60)),
        metricExportInterval: .seconds(3_600)
      )
      configuration.tailSampling = try tailConfiguration(slowThreshold: .seconds(1))
      let runtime = try TelemetryRuntime(
        configuration: configuration,
        transport: capture.transport,
        authenticator: .none
      )

      try await runtime.client.withEffectTrace(
        effect: "success",
        longLived: false,
        parentContext: nil
      ) {}
      #expect(runtime.tailSamplingSnapshot?.retainedSpanCount == 1)
      #expect(runtime.diagnostics.traces.queueDepth == 0)
      _ = await runtime.forceFlush(timeout: .milliseconds(50))
      #expect(capture.requests.filter { $0.signal == .traces }.isEmpty)

      let result = await runtime.disableAndDiscardPending()
      #expect(result.traces.pendingItems == 0)
      #expect(runtime.tailSamplingSnapshot?.retainedSpanCount == 0)
      #expect(capture.requests.filter { $0.signal == .traces }.isEmpty)
    }

    @Test("production promotion enters the existing bounded trace and log delivery path")
    func runtimePromotionDelivery() async throws {
      let capture = InMemoryEncodedRequestCollector()
      let spanObserver = ObserverSpanExporter()
      let logObserver = ObserverLogRecordExporter()
      var configuration = TelemetryRuntime.Configuration(
        serviceName: "test-suite",
        endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
        samplingRatio: 0,
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
        ),
        traces: .init(maximumQueueSize: 128, maximumBatchSize: 16),
        logs: .init(maximumQueueSize: 64, maximumBatchSize: 16),
        metricExportInterval: .seconds(3_600)
      )
      configuration.tailSampling = try tailConfiguration(slowThreshold: .seconds(1))
      configuration.observerExporters = .init(
        spanExporters: [spanObserver],
        logRecordExporters: [logObserver]
      )
      let runtime = try TelemetryRuntime(
        configuration: configuration,
        transport: capture.transport,
        authenticator: .none
      )

      do {
        let _: Void = try await runtime.client.withEffectTrace(
          effect: "failure",
          longLived: false,
          parentContext: nil
        ) {
          #expect(runtime.client.log(.info, "Runtime breadcrumb") == .recorded)
          throw PhaseOneFailure.failed
        }
      } catch is PhaseOneFailure {
      }
      let result = await runtime.forceFlush(timeout: .seconds(2))

      #expect(result.traces.status == .success)
      #expect(result.logs.status == .success)
      #expect(Set(capture.requests.compactMap(\.signal)) == [.traces, .logs])
      #expect(runtime.tailSamplingSnapshot?.retainedSpanCount == 0)
      let observedError = try #require(logObserver.records.first { $0.severity == .error })
      let observedSpan = try #require(spanObserver.spans.first)
      #expect(observedError.spanContext?.traceId == observedSpan.traceId)
      _ = await runtime.shutdown(timeout: .seconds(1))
    }

    @Test("a deliberately discarded normal trace cannot leave an error correlation")
    func discardedTraceStripsErrorCorrelation() async throws {
      let logObserver = ObserverLogRecordExporter()
      var configuration = TelemetryRuntime.Configuration(
        serviceName: "test-suite",
        endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
        samplingRatio: 0,
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
        ),
        traces: .init(maximumQueueSize: 1, maximumBatchSize: 1),
        logs: .init(maximumQueueSize: 1, maximumBatchSize: 1),
        metricExportInterval: .seconds(3_600)
      )
      configuration.observerExporters = .init(logRecordExporters: [logObserver])
      let runtime = try TelemetryRuntime(
        configuration: configuration,
        transport: InMemoryEncodedRequestCollector().transport,
        authenticator: .none
      )

      do {
        let _: Void = try await runtime.client.withEffectTrace(
          effect: "failure",
          longLived: false,
          parentContext: nil
        ) {
          throw PhaseOneFailure.failed
        }
      } catch is PhaseOneFailure {
      }
      _ = await runtime.forceFlush(timeout: .seconds(1))

      let error = try #require(logObserver.records.first { $0.severity == .error })
      #expect(error.spanContext == nil)
      _ = await runtime.shutdown(timeout: .seconds(1))
    }
  }
}

private func phaseOneLongMetricTotal(
  _ name: String,
  metrics: [MetricData]
) -> Int {
  metrics
    .filter { $0.name == name }
    .flatMap(\.data.points)
    .compactMap { $0 as? LongPointData }
    .reduce(0) { $0 + $1.value }
}

private func tailConfiguration(
  slowThreshold: Duration
) throws -> TelemetryTailSamplingConfiguration {
  .enabled(
    try TelemetryTailSamplingPolicy(
      slowTraceThreshold: slowThreshold,
      maximumTraceCount: 64,
      maximumRetainedSpanCount: 128,
      maximumRetainedBreadcrumbCount: 64,
      maximumRetainedBytes: 512 * 1_024,
      maximumAge: .seconds(2)
    )
  )
}

extension TelemetryHostContext {
  fileprivate var captured: CapturedTelemetryHostContext {
    CapturedTelemetryHostContext(
      processSessionID: processSessionID,
      platform: platform,
      processKind: processKind
    )
  }
}

private actor PhaseOneAsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}

private final class PhaseOneSpanContextCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: SpanContext?

  var value: SpanContext? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private final class PhaseOneTailClock: @unchecked Sendable {
  private let lock = NSLock()
  private var sleeps = 0
  let now = Date(timeIntervalSince1970: 1_000)

  var sleepCount: Int {
    lock.withLock { sleeps }
  }

  var runtimeClock: TelemetryRuntimeClock {
    TelemetryRuntimeClock(
      now: { [now] in now },
      sleep: { [weak self] _ in
        self?.lock.withLock {
          self?.sleeps += 1
        }
        try await Task.sleep(for: .seconds(30))
      },
      randomUnit: { 0.5 }
    )
  }
}

#if DEBUG
  private final class PhaseOneEvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var count: Int {
      lock.withLock { storage }
    }

    func next(_ value: String) -> String {
      lock.withLock {
        storage += 1
      }
      return value
    }
  }

  private final class PhaseOneRenderCapture: @unchecked Sendable {
    struct Value: Equatable {
      let severity: TelemetryLogSeverity
      let body: String
    }

    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
      lock.withLock { storage }
    }

    func append(severity: TelemetryLogSeverity, body: String) {
      lock.withLock {
        storage.append(.init(severity: severity, body: body))
      }
    }
  }
#endif
