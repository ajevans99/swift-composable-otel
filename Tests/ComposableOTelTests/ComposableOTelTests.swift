import ComposableArchitecture
import ComposableOTelTesting
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

let testSchema = try! TelemetrySchema(
  features: ["counter", "sensitive"],
  actions: ["increment", "decrement", "fetch-and-set", "set-count", "submit"],
  effects: [
    "fetch-count", "long-lived", "cancelled-long-lived", "propagation", "failure",
    "cancellation", "recovered-cancellation", "translated-cancellation", "success",
    "long-lived-success", "error", "cancelled",
  ],
  dependencies: ["test-dependency", "cache", "awaited", "child-task"],
  operations: ["get-value", "failing", "load"],
  routes: ["settings"],
  errorTypes: ["test-error"],
  errorCategories: ["internal"],
  errorCodes: ["failed"],
  services: ["test-suite", "metadata-test"],
  serviceVersions: ["1.2.3", "1.2.3-alpha.1+Build45", "release-1"]
)

func testPolicy(
  signals: TelemetrySignalConfiguration = .init(),
  classifyError: @escaping @Sendable (any Error) -> TelemetryErrorMetadata = { _ in
    TelemetryErrorMetadata(
      type: "test-error",
      category: "internal",
      code: "failed",
      handled: false,
      retryable: false
    )
  }
) -> TelemetryPolicy {
  TelemetryPolicy(schema: testSchema, signals: signals, classifyError: classifyError)
}

@Reducer
struct CounterFeature {
  struct State: Equatable {
    var count = 0
  }

  enum Action: Equatable {
    case increment
    case decrement
    case fetchAndSet
    case setCount(Int)

    var telemetryID: ActionID {
      switch self {
      case .increment:
        "increment"
      case .decrement:
        "decrement"
      case .fetchAndSet:
        "fetch-and-set"
      case .setCount:
        "set-count"
      }
    }
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += 1
        return .none
      case .decrement:
        state.count -= 1
        return .none
      case .fetchAndSet:
        return .tracedRun(effect: "fetch-count") { send in
          try await Task.sleep(for: .milliseconds(10))
          await send(.setCount(42))
        }
      case .setCount(let value):
        state.count = value
        return .none
      }
    }
    .instrumented(
      feature: "counter",
      action: \.telemetryID,
      stateChangeToken: { StateChangeToken(UInt64(bitPattern: Int64($0.count))) }
    )
  }
}

@Reducer
private struct SensitiveFeature {
  struct State: Equatable, CustomStringConvertible {
    var secret = sentinelSecret
    var revision = 0
    var description: String { "state-\(secret)" }
  }

  enum Action: Equatable, CustomStringConvertible {
    case submit(String)
    var description: String { "submit-\(sentinelSecret)" }
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .submit:
        state.revision += 1
        return .none
      }
    }
    .instrumented(feature: "sensitive", action: { _ in "submit" })
  }
}

private let sentinelSecret = "sentinel-secret-9f4c2"

@Suite("ComposableOTel")
struct ComposableOTelAllTests {
  @Suite("Typed schema")
  struct TypedSchemaTests {
    @Test("validates identifiers without normalizing unsafe input")
    func identifierValidation() {
      #expect(FeatureID(validating: "feature-name") != nil)
      #expect(FeatureID(validating: "") == nil)
      #expect(FeatureID(validating: "Feature") == nil)
      #expect(FeatureID(validating: "https://example.invalid/id") == nil)
      #expect(FeatureID(validating: String(repeating: "a", count: 49)) == nil)
      #expect(ServiceVersionID(validating: "1.2.3") != nil)
      #expect(ServiceVersionID(validating: "1.2.3-alpha.1+Build45") != nil)
    }

    @Test("rejects schema cardinality overflow without values")
    func schemaLimit() {
      let values = (0...TelemetrySchema.featureLimit).map {
        FeatureID(validating: "feature-\($0)")!
      }
      #expect(throws: TelemetrySchema.ValidationError.self) {
        _ = try TelemetrySchema(features: values)
      }
    }

    @Test("aggregates identifiers outside the finite schema")
    func schemaAggregation() {
      let dynamic = FeatureID(validating: "dynamic-feature")!
      #expect(testSchema.bounded(dynamic) == .other)
    }

    @Test("malformed raw identifier fields aggregate instead of disappearing")
    func malformedRawValues() {
      let policy = testPolicy()
      let attributes = policy.sanitizedSpanAttributes([
        TCAAttributes.featureName: .string("https://invalid.example"),
        TCAAttributes.actionName: .int(42),
      ])
      let resource = policy.sanitizedResourceAttributes([
        "service.name": .string("Invalid Service"),
        "service.version": .int(1),
      ])
      #expect(attributes[TCAAttributes.featureName] == .string("other"))
      #expect(attributes[TCAAttributes.actionName] == .string("other"))
      #expect(resource["service.name"] == .string("other"))
      #expect(resource["service.version"] == .string("other"))
    }
  }

  @Suite("Reducer instrumentation")
  struct ReducerTests {
    @Test("uses a stable span name and typed action attribute")
    @MainActor
    func spanPerAction() async throws {
      let (client, collectors) = TelemetryClient.test(policy: testPolicy())
      let store = TestStore(initialState: CounterFeature.State()) {
        CounterFeature()
      } withDependencies: {
        $0.composableOTel = client
      }

      await store.send(.increment) { $0.count = 1 }
      collectors.forceFlush()

      let span = try #require(
        collectors.spans.spans(named: ComposableOTelSemantics.Spans.reducer).first
      )
      #expect(span.attributes[TCAAttributes.featureName] == .string("counter"))
      #expect(span.attributes[TCAAttributes.actionName] == .string("increment"))
      #expect(span.attributes[TCAAttributes.stateChanged] == .bool(true))
    }

    @Test("never describes actions, associated values, or state")
    @MainActor
    func actionAndStateLeakage() async throws {
      let metricReader = InMemoryMetricReader()
      let (client, collectors) = TelemetryClient.test(
        metricReader: metricReader,
        policy: testPolicy()
      )
      let store = TestStore(initialState: SensitiveFeature.State()) {
        SensitiveFeature()
      } withDependencies: {
        $0.composableOTel = client
      }

      await store.send(.submit(sentinelSecret)) {
        $0.revision = 1
      }
      collectors.forceFlush()

      #expect(collectors.logs.allRecords.isEmpty)
      #expect(try !encoded(collectors.spans.spans).contains(sentinelSecret))
      #expect(try !encoded(metricReader.metrics).contains(sentinelSecret))
      let span = try #require(
        collectors.spans.spans(named: ComposableOTelSemantics.Spans.reducer).first
      )
      #expect(span.attributes[TCAAttributes.stateChanged] == nil)
    }

    @Test("action logs are disabled by default")
    @MainActor
    func defaultLogsDisabled() async {
      let (client, collectors) = TelemetryClient.test(policy: testPolicy())
      let store = TestStore(initialState: CounterFeature.State()) {
        CounterFeature()
      } withDependencies: {
        $0.composableOTel = client
      }
      await store.send(.increment) { $0.count = 1 }
      #expect(collectors.logs.allRecords.isEmpty)
    }
  }

  @Suite("Signal controls")
  struct SignalControlTests {
    @Test("metrics remain enabled when traces and logs are disabled")
    func metricsOnly() {
      let reader = InMemoryMetricReader()
      let (client, collectors) = TelemetryClient.test(
        metricReader: reader,
        policy: testPolicy(
          signals: .init(tracesEnabled: false, metricsEnabled: true, logsEnabled: false)
        )
      )
      client.recordNavigation(.push, route: "settings")
      collectors.forceFlush()

      #expect(collectors.spans.spans.isEmpty)
      #expect(collectors.logs.allRecords.isEmpty)
      #expect(!reader.metrics(named: ComposableOTelSemantics.Metrics.navigationTransitions).isEmpty)
    }

    @Test("logs remain enabled when traces and metrics are disabled")
    func logsOnly() {
      let reader = InMemoryMetricReader()
      let (client, collectors) = TelemetryClient.test(
        metricReader: reader,
        policy: testPolicy(
          signals: .init(tracesEnabled: false, metricsEnabled: false, logsEnabled: true)
        )
      )
      client.recordNavigation(.present, route: "settings")
      collectors.forceFlush()

      #expect(collectors.spans.spans.isEmpty)
      #expect(reader.metrics.isEmpty)
      #expect(collectors.logs.allRecords.count == 1)
    }
  }

  @Suite("Privacy boundary")
  struct PrivacyBoundaryTests {
    @Test("sanitizes raw SDK span names, resources, attributes, events, links, and status")
    func rawSpanLeakage() throws {
      let collector = InMemorySpanCollector()
      let policy = testPolicy()
      let exporter = PrivacyPreservingSpanExporter(exporter: collector, policy: policy)
      let provider = TracerProviderBuilder()
        .with(
          resource: Resource(attributes: [
            "service.name": .string(sentinelSecret),
            "resource.secret": .string(sentinelSecret),
          ])
        )
        .add(spanProcessor: SimpleSpanProcessor(spanExporter: exporter))
        .build()
      let tracer = provider.get(
        instrumentationName: ComposableOTelMetadata.instrumentationName,
        instrumentationVersion: ComposableOTelMetadata.version
      )
      let span = tracer.spanBuilder(spanName: sentinelSecret)
        .setAttribute(key: "attribute.secret", value: sentinelSecret)
        .startSpan()
      span.addEvent(
        name: sentinelSecret,
        attributes: ["event.secret": .string(sentinelSecret)]
      )
      span.status = .error(description: sentinelSecret)
      span.end()
      let unsafeScopeSpan = provider.get(
        instrumentationName: sentinelSecret,
        instrumentationVersion: sentinelSecret
      ).spanBuilder(spanName: sentinelSecret).startSpan()
      unsafeScopeSpan.end()
      provider.forceFlush()

      let exported = try #require(collector.spans.first)
      #expect(collector.spans.count == 1)
      #expect(exported.name == ComposableOTelSemantics.Spans.unknown)
      #expect(exported.attributes.isEmpty)
      #expect(exported.events.isEmpty)
      #expect(exported.links.isEmpty)
      #expect(exported.status == .error(description: "Operation failed"))
      #expect(exported.resource.attributes["service.name"] == .string("other"))
      #expect(exported.instrumentationScope.name == ComposableOTelMetadata.instrumentationName)
      #expect(try !encoded(exported).contains(sentinelSecret))
    }

    @Test("sanitizes raw SDK log bodies, attributes, event names, and resources")
    func rawLogLeakage() throws {
      let collector = InMemoryLogCollector()
      let policy = testPolicy(
        signals: .init(tracesEnabled: false, metricsEnabled: false, logsEnabled: true)
      )
      let exporter = PrivacyPreservingLogRecordExporter(exporter: collector, policy: policy)
      let record = ReadableLogRecord(
        resource: Resource(attributes: [
          "service.name": .string(sentinelSecret),
          "resource.secret": .string(sentinelSecret),
        ]),
        instrumentationScopeInfo: InstrumentationScopeInfo(name: "raw-test"),
        timestamp: Date(),
        severity: .error,
        body: .string(sentinelSecret),
        attributes: ["log.secret": .string(sentinelSecret)],
        eventName: sentinelSecret
      )
      _ = exporter.export(logRecords: [record], explicitTimeout: nil)

      let exported = try #require(collector.allRecords.first)
      #expect(exported.body == .string(ComposableOTelSemantics.LogBodies.unknown))
      #expect(exported.attributes.isEmpty)
      #expect(exported.eventName == nil)
      #expect(exported.resource.attributes["service.name"] == .string("other"))
      #expect(exported.instrumentationScopeInfo.name == ComposableOTelMetadata.instrumentationName)
      #expect(exported.instrumentationScopeInfo.version == ComposableOTelMetadata.version)
      #expect(try !encoded(exported).contains(sentinelSecret))
    }

    @Test("error descriptions never reach spans, events, status, or logs")
    func errorLeakage() async throws {
      struct SensitiveError: Error, CustomStringConvertible, LocalizedError {
        var description: String { sentinelSecret }
        var errorDescription: String? { sentinelSecret }
      }

      let (client, collectors) = TelemetryClient.test(
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: true, logsEnabled: true)
        )
      )
      do {
        let _: Int = try await withDependencies {
          $0.composableOTel = client
        } operation: {
          try await tracedCall(
            dependency: "test-dependency",
            operation: "failing"
          ) {
            throw SensitiveError()
          }
        }
        Issue.record("Expected error")
      } catch is SensitiveError {
      }
      collectors.forceFlush()

      #expect(try !encoded(collectors.spans.spans).contains(sentinelSecret))
      #expect(try !encoded(collectors.logs.allRecords).contains(sentinelSecret))
      let span = try #require(
        collectors.spans.spans(named: ComposableOTelSemantics.Spans.dependency).first
      )
      #expect(span.status == .error(description: "Operation failed"))
      #expect(span.events.first?.attributes[TCAAttributes.errorType] == .string("test-error"))
      #expect(
        collectors.logs.allRecords.first?.body
          == .string(ComposableOTelSemantics.LogBodies.dependencyFailed)
      )
      #expect(
        collectors.logs.allRecords.first?.attributes[TCAAttributes.operationName]
          == .string("failing")
      )
    }
  }

  @Suite("Cardinality")
  struct CardinalityTests {
    @Test("dynamic routes and effects aggregate without changing names or series count")
    func boundedNamesAndSeries() async throws {
      let reader = InMemoryMetricReader()
      let (client, collectors) = TelemetryClient.test(
        metricReader: reader,
        policy: testPolicy()
      )

      for index in 0..<100 {
        let route = RouteID(validating: "dynamic-route-\(index)")!
        client.recordNavigation(.push, route: route)
        let effect = EffectID(validating: "dynamic-effect-\(index)")!
        try await client.withEffectTrace(
          effect: effect,
          longLived: false,
          parentContext: nil
        ) {}
      }
      collectors.forceFlush()

      #expect(
        Set(collectors.spans.spans.map(\.name)) == [
          ComposableOTelSemantics.Spans.navigation,
          ComposableOTelSemantics.Spans.effect,
        ]
      )
      #expect(
        collectors.spans.spans.allSatisfy {
          $0.attributes[TCAAttributes.navigationRoute] == nil
            || $0.attributes[TCAAttributes.navigationRoute] == .string("other")
        }
      )
      #expect(
        collectors.spans.spans.allSatisfy {
          $0.attributes[TCAAttributes.effectName] == nil
            || $0.attributes[TCAAttributes.effectName] == .string("other")
        }
      )
      #expect(
        points(
          named: ComposableOTelSemantics.Metrics.navigationTransitions,
          in: reader.metrics
        ).count == 1
      )
      #expect(
        points(named: ComposableOTelSemantics.Metrics.effectsStarted, in: reader.metrics).count == 1
      )
      #expect(try !encoded(collectors.spans.spans).contains("dynamic-route-99"))
      #expect(try !encoded(reader.metrics).contains("dynamic-effect-99"))
    }

    @Test("views and exporter sanitize metric dimensions and drop unknown instruments")
    func rawMetricLeakage() throws {
      let policy = testPolicy()
      let capture = CapturingMetricExporter()
      let exporter = PrivacyPreservingMetricExporter(exporter: capture, policy: policy)
      let reader = PeriodicMetricReaderBuilder(exporter: exporter)
        .setInterval(timeInterval: 3_600)
        .build()
      let resource = Resource(
        attributes: policy.sanitizedResourceAttributes([
          "service.name": .string("test-suite")
        ])
      )
      let builder = MeterProviderSdk.builder()
        .setResource(resource: resource)
        .registerMetricReader(reader: reader)
      ComposableOTelMetricConfiguration.registerViews(on: builder, policy: policy)
      let provider = builder.build()
      let meter =
        provider
        .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
        .setInstrumentationVersion(instrumentationVersion: ComposableOTelMetadata.version)
        .build()
      let counter = meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.actionsDispatched
      ).build()
      counter.add(
        value: 1,
        attributes: [
          TCAAttributes.featureName: .string("dynamic-feature"),
          TCAAttributes.actionName: .string("dynamic-action"),
          "metric.secret": .string(sentinelSecret),
        ]
      )
      let unknown = meter.counterBuilder(name: sentinelSecret).build()
      unknown.add(value: 1, attributes: ["metric.secret": .string(sentinelSecret)])
      let unsafeMeter =
        provider
        .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
        .setInstrumentationVersion(instrumentationVersion: sentinelSecret)
        .build()
      let unsafeScopeCounter = unsafeMeter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.actionsDispatched
      ).build()
      unsafeScopeCounter.add(value: 1)
      _ = provider.forceFlush()

      let metric = try #require(
        capture.metrics.first {
          $0.name == ComposableOTelSemantics.Metrics.actionsDispatched
        }
      )
      let point = try #require(metric.data.points.first)
      #expect(point.attributes[TCAAttributes.featureName] == .string("other"))
      #expect(point.attributes[TCAAttributes.actionName] == .string("other"))
      #expect(point.attributes["metric.secret"] == nil)
      #expect(capture.metrics.allSatisfy { $0.name != sentinelSecret })
      #expect(try !encoded(capture.metrics).contains(sentinelSecret))
    }
  }

  @Suite("Metric semantics")
  struct MetricSemanticsTests {
    @Test("package metrics declare descriptions and units")
    func descriptionsAndUnits() async {
      let reader = InMemoryMetricReader()
      let (client, collectors) = TelemetryClient.test(
        metricReader: reader,
        policy: testPolicy()
      )
      client.recordNavigation(.push, route: "settings")
      _ = await withDependencies {
        $0.composableOTel = client
      } operation: {
        await tracedCall(dependency: "cache", operation: "load") { 1 }
      }
      collectors.forceFlush()

      #expect(reader.metrics.allSatisfy { !$0.description.isEmpty && !$0.unit.isEmpty })
      #expect(
        reader.metrics(named: ComposableOTelSemantics.Metrics.dependencyDuration).first?.unit
          == "ms"
      )
      #expect(
        reader.metrics(named: ComposableOTelSemantics.Metrics.navigationTransitions).first?.unit
          == "{transition}"
      )
    }
  }

  @Suite("Package metadata")
  struct PackageMetadataTests {
    @Test("uses one instrumentation version for traces and logs")
    func instrumentationScopes() throws {
      let (client, collectors) = TelemetryClient.test(
        policy: testPolicy(
          signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: true)
        )
      )
      client.recordNavigation(.push, route: "settings")
      collectors.forceFlush()

      let span = try #require(collectors.spans.spans.first)
      #expect(span.instrumentationScope.name == ComposableOTelMetadata.instrumentationName)
      #expect(span.instrumentationScope.version == ComposableOTelMetadata.version)
      let log = try #require(collectors.logs.allRecords.first)
      #expect(log.instrumentationScopeInfo.name == ComposableOTelMetadata.instrumentationName)
      #expect(log.instrumentationScopeInfo.version == ComposableOTelMetadata.version)
    }

    @Test("uses package version in a bounded bootstrap resource")
    func bootstrapResource() {
      let resource = TelemetryBootstrap.makeResource(
        serviceName: "metadata-test",
        serviceVersion: "1.2.3",
        environment: .production(endpoint: "https://unused.invalid"),
        policy: testPolicy()
      )
      #expect(resource.attributes["service.name"] == .string("metadata-test"))
      #expect(resource.attributes["service.version"] == .string("1.2.3"))
      #expect(
        resource.attributes["telemetry.distro.version"]
          == .string(ComposableOTelMetadata.version)
      )
      #expect(resource.attributes["telemetry.sdk.name"] == .string("opentelemetry"))
      #expect(resource.attributes["os.version"] == nil)
    }

    @Test("keeps the release version in one source file")
    func authoritativeVersionLiteral() throws {
      let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let sourcesRoot = repositoryRoot.appendingPathComponent("Sources")
      let expression = try NSRegularExpression(pattern: #"\b[0-9]+\.[0-9]+\.[0-9]+\b"#)
      let enumerator = try #require(
        FileManager.default.enumerator(
          at: sourcesRoot,
          includingPropertiesForKeys: [.isRegularFileKey]
        )
      )
      var occurrences: [String] = []

      for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let matches = expression.matches(
          in: contents,
          range: NSRange(contents.startIndex..., in: contents)
        )
        let relativePath = fileURL.path.replacingOccurrences(
          of: sourcesRoot.path + "/",
          with: ""
        )
        occurrences.append(contentsOf: repeatElement(relativePath, count: matches.count))
      }
      #expect(occurrences == ["ComposableOTel/ComposableOTelMetadata.swift"])
    }
  }
}

private final class CapturingMetricExporter: MetricExporter, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [MetricData] = []

  var metrics: [MetricData] {
    lock.withLock { storage }
  }

  func export(metrics: [MetricData]) -> ExportResult {
    lock.withLock {
      storage.append(contentsOf: metrics)
    }
    return .success
  }

  func flush() -> ExportResult { .success }
  func shutdown() -> ExportResult { .success }

  func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality {
    .cumulative
  }
}

private func encoded<T: Encodable>(_ value: T) throws -> String {
  String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
}

private func points(named name: String, in metrics: [MetricData]) -> [PointData] {
  metrics.filter { $0.name == name }.flatMap(\.data.points)
}
