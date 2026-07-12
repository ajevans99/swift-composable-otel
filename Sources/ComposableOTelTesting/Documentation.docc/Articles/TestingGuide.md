# Testing Guide

Inspect instrumentation with the `ComposableOTelTesting` in-memory helpers.

## Create and inject a test client

```swift
import ComposableOTelTesting

let (telemetry, collectors) = TelemetryClient.test()
let store = TestStore(initialState: MyFeature.State()) {
  MyFeature()
} withDependencies: {
  $0.composableOTel = telemetry
}
```

The returned ``TestCollectors`` contains span and log collectors plus the optional metric reader.

## Assert on spans

Flush the test tracer provider after exercising the feature:

```swift
await store.send(.someAction) {
  $0.someValue = expected
}

collectors.forceFlush()
collectors.spans.assertSpanExists(named: "reducer/MyFeature")
collectors.spans.assertNoSpan(named: "reducer/OtherFeature")

let spans = collectors.spans.spans(named: "effect/fetchData")
#expect(!spans.isEmpty)
```

## Inspect logs

The test client caches its in-memory logger without replacing global providers:

```swift
let errors = collectors.logs.records(withSeverity: .error)
let matching = collectors.logs.records(containing: "Dependency call failed")
```

## Inspect metrics

Pass an ``InMemoryMetricReader`` when creating the client:

```swift
let metricReader = InMemoryMetricReader()
let (telemetry, collectors) = TelemetryClient.test(metricReader: metricReader)

// Exercise instrumentation, then request collection.
let metrics = metricReader.collectMetrics()
```

The metric reader API is provisional in `0.2.2`. The package regression suite uses it to verify
effect terminal counters and that active-effect values return to zero.

## Global compatibility tests

``ComposableOTel/TelemetryClient/test(metricReader:errorDetailPolicy:)`` keeps providers local, so
separately injected clients can run concurrently. Only the deprecated `configureTestTelemetry`
helper replaces process-global providers. Serialize suites that still use that compatibility API:

```swift
@Suite("Legacy global telemetry", .serialized)
struct LegacyGlobalTelemetryTests {
  // Tests.
}
```
