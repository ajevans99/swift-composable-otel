import ComposableArchitecture
import ComposableOTel
import ComposableOTelTesting
import Dependencies
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

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

// All telemetry tests must be serialized since they share OpenTelemetry.instance
@Suite("ComposableOTel", .serialized)
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

      let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
      provider.forceFlush()

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

      let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
      provider.forceFlush()

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

      let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
      provider.forceFlush()

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

      let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
      provider.forceFlush()

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
      let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
      provider.forceFlush()

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

      let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
      provider.forceFlush()

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

      let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
      provider.forceFlush()

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

      let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
      provider.forceFlush()

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
