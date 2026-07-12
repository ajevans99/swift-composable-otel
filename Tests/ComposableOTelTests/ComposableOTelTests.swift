import ComposableArchitecture
import ComposableOTel
import ComposableOTelTesting
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

@testable import ComposableOTelExporters

// MARK: - Test Reducer

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
        return .tracedRun(name: "fetchCount") { send in
          try await Task.sleep(for: .milliseconds(10))
          await send(.setCount(42))
        }
      case .setCount(let value):
        state.count = value
        return .none
      }
    }
    .instrumented(name: "CounterFeature")
  }
}

@Suite("ComposableOTel")
struct ComposableOTelAllTests {

  // MARK: - InstrumentedReducer Tests

  @Suite("InstrumentedReducer")
  struct InstrumentedReducerTests {
    @Test("produces a span per action")
    @MainActor
    func spanPerAction() async {
      let (client, collectors) = TelemetryClient.test()

      let store = TestStore(initialState: CounterFeature.State()) {
        CounterFeature()
      } withDependencies: {
        $0.composableOTel = client
      }

      await store.send(.increment) { $0.count = 1 }

      // flush spans
      collectors.forceFlush()

      let spans = collectors.spans.spans(named: "reducer/CounterFeature")
      #expect(!spans.isEmpty, "Expected at least one reducer span")

      if let span = spans.first {
        #expect(span.attributes["tca.action.type"]?.description == "increment")
      }
    }

    @Test("records action type attribute for decrement")
    @MainActor
    func actionTypeAttribute() async {
      let (client, collectors) = TelemetryClient.test()

      let store = TestStore(initialState: CounterFeature.State()) {
        CounterFeature()
      } withDependencies: {
        $0.composableOTel = client
      }

      await store.send(.decrement) { $0.count = -1 }

      // flush spans
      collectors.forceFlush()

      let spans = collectors.spans.spans(named: "reducer/CounterFeature")
      #expect(!spans.isEmpty)
      if let span = spans.first {
        #expect(span.attributes["tca.action.type"]?.description == "decrement")
      }
    }

    @Test("multiple actions produce multiple spans")
    @MainActor
    func multipleSpans() async {
      let (client, collectors) = TelemetryClient.test()

      let store = TestStore(initialState: CounterFeature.State()) {
        CounterFeature()
      } withDependencies: {
        $0.composableOTel = client
      }

      await store.send(.increment) { $0.count = 1 }
      await store.send(.increment) { $0.count = 2 }
      await store.send(.decrement) { $0.count = 1 }

      // flush spans
      collectors.forceFlush()

      let spans = collectors.spans.spans(named: "reducer/CounterFeature")
      #expect(spans.count >= 3)
    }

    @Test("reducer name defaults to type name when not specified")
    @MainActor
    func defaultReducerName() async {
      let (client, collectors) = TelemetryClient.test()

      let store = TestStore(
        initialState: CounterFeature.State()
      ) {
        Reduce<CounterFeature.State, CounterFeature.Action> { state, action in
          switch action {
          case .increment:
            state.count += 1
            return .none
          default:
            return .none
          }
        }
        .instrumented()
      } withDependencies: {
        $0.composableOTel = client
      }

      await store.send(.increment) { $0.count = 1 }

      // flush spans
      collectors.forceFlush()

      let spans = collectors.spans.spans(named: "reducer/Reduce")
      #expect(!spans.isEmpty)
    }
  }

  // MARK: - TracedEffect Tests

  @Suite("TracedEffect")
  struct TracedEffectTests {
    @Test("tracedRun produces an effect span")
    @MainActor
    func tracedRunSpan() async {
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

      try? await Task.sleep(for: .milliseconds(50))
      // flush spans
      collectors.forceFlush()

      let effectSpans = collectors.spans.spans(named: "effect/fetchCount")
      #expect(!effectSpans.isEmpty, "Expected an effect span for fetchCount")
    }
  }

  // MARK: - TracedCall Tests

  @Suite("TracedCall")
  struct TracedCallTests {
    @Test("tracedCall creates a dependency span")
    func dependencySpan() async {
      let (client, collectors) = TelemetryClient.test()

      let result: Int = await withDependencies {
        $0.composableOTel = client
      } operation: {
        await tracedCall("testDep", method: "getValue") {
          42
        }
      }

      #expect(result == 42)

      // flush spans
      collectors.forceFlush()

      collectors.spans.assertSpanExists(named: "dependency/testDep/getValue")
    }

    @Test("tracedCall records error on throw")
    func dependencyError() async {
      let (client, collectors) = TelemetryClient.test()

      struct TestError: Error {}

      do {
        let _: Int = try await withDependencies {
          $0.composableOTel = client
        } operation: {
          try await tracedCall("testDep", method: "failing") {
            throw TestError()
          }
        }
        Issue.record("Should have thrown")
      } catch {
        // expected
      }

      // flush spans
      collectors.forceFlush()

      let spans = collectors.spans.spans(named: "dependency/testDep/failing")
      #expect(!spans.isEmpty)
      if let span = spans.first {
        #expect(span.status.isError)
      }
    }

    @Test("non-throwing tracedCall works")
    func nonThrowingCall() async {
      let (client, collectors) = TelemetryClient.test()

      let result: String = await withDependencies {
        $0.composableOTel = client
      } operation: {
        await tracedCall("cache", method: "load") {
          "cached_value"
        }
      }

      #expect(result == "cached_value")

      // flush spans
      collectors.forceFlush()

      collectors.spans.assertSpanExists(named: "dependency/cache/load")
    }
  }

  // MARK: - ErrorDetailPolicy Tests

  @Suite("ErrorDetailPolicy")
  struct ErrorDetailPolicyTests {
    @Test("redacted policy returns context only")
    func redactedPolicy() {
      let policy = ErrorDetailPolicy.redacted
      struct Oops: Error {}
      let body = policy.errorBody(for: Oops(), context: "Something failed")
      #expect(body == "Something failed")
      #expect(policy.isRedacted == true)
    }

    @Test("full policy returns error description")
    func fullPolicy() {
      let policy = ErrorDetailPolicy.full
      struct Oops: Error, CustomStringConvertible {
        var description: String { "detailed info" }
      }
      let body = policy.errorBody(for: Oops(), context: "Something failed")
      #expect(body == "detailed info")
      #expect(policy.isRedacted == false)
    }

    @Test("safeSummary policy uses provided function")
    func safeSummaryPolicy() {
      let policy = ErrorDetailPolicy.safeSummary { _ in "sanitized" }
      struct Oops: Error {}
      let body = policy.errorBody(for: Oops(), context: "Something failed")
      #expect(body == "sanitized")
      #expect(policy.isRedacted == false)
    }
  }

  // MARK: - TelemetryClient Tests

  @Suite("TelemetryClient")
  struct TelemetryClientTests {
    @Test("default error detail policy is redacted")
    func defaultRedacted() {
      let (client, _) = TelemetryClient.test()
      #expect(client.errorDetailPolicy.isRedacted == true)
    }
  }

  // MARK: - Package Metadata Tests

  @Suite("Package metadata")
  struct PackageMetadataTests {
    @Test("uses one instrumentation version for traces and logs")
    func instrumentationScopes() throws {
      let (client, collectors) = TelemetryClient.test()

      let span = client.tracer.spanBuilder(spanName: "metadata").startSpan()
      span.end()
      client.info("metadata")

      collectors.forceFlush()

      let exportedSpan = try #require(collectors.spans.spans(named: "metadata").first)
      #expect(
        exportedSpan.instrumentationScope.name == ComposableOTelMetadata.instrumentationName
      )
      #expect(exportedSpan.instrumentationScope.version == ComposableOTelMetadata.version)

      let exportedLog = try #require(collectors.logs.allRecords.first)
      #expect(
        exportedLog.instrumentationScopeInfo.name == ComposableOTelMetadata.instrumentationName
      )
      #expect(exportedLog.instrumentationScopeInfo.version == ComposableOTelMetadata.version)
    }

    @Test("uses package version in bootstrap resource")
    func bootstrapResource() {
      let resource = TelemetryBootstrap.makeResource(
        serviceName: "metadata-test",
        serviceVersion: "1",
        environment: .production(endpoint: "https://unused.invalid")
      )

      #expect(
        resource.attributes["telemetry.distro.name"]
          == .string(ComposableOTelMetadata.packageName)
      )
      #expect(
        resource.attributes["telemetry.distro.version"]
          == .string(ComposableOTelMetadata.version)
      )
      #expect(resource.attributes["telemetry.sdk.name"] == .string("opentelemetry"))
    }

    @Test("keeps the release version in one source file")
    func authoritativeVersionLiteral() throws {
      let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let sourcesRoot = repositoryRoot.appendingPathComponent("Sources")
      let expression = try NSRegularExpression(pattern: #"\b[0-9]+\.[0-9]+\.[0-9]+\b"#)
      let fileManager = FileManager.default
      let enumerator = try #require(
        fileManager.enumerator(
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

  // MARK: - Attributes Tests

  @Suite("Attributes")
  struct AttributesTests {
    @Test("attribute keys have correct prefixes")
    func attributeKeyPrefixes() {
      #expect(TCAAttributes.reducerName == "tca.reducer.name")
      #expect(TCAAttributes.actionType == "tca.action.type")
      #expect(TCAAttributes.effectName == "tca.effect.name")
      #expect(TCAAttributes.dependencyName == "tca.dependency.name")
    }
  }
}
