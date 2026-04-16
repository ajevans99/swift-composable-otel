# Testing Guide

Verify your telemetry instrumentation with in-memory collectors.

## Overview

ComposableOTel provides a dedicated `ComposableOTelTesting` module with
in-memory span and metric collectors, plus assertion helpers.

### Creating a Test Client

Use the `TelemetryClient.test()` factory to get a client wired to
in-memory storage:

```swift
import ComposableOTelTesting

let (client, collector) = TelemetryClient.test()
```

### Injecting Into a TestStore

Pass the test client through `withDependencies`:

```swift
let store = TestStore(initialState: MyFeature.State()) {
  MyFeature()
} withDependencies: {
  $0.composableOTel = client
}
```

### Asserting on Spans

After exercising actions, flush the provider and query the collector:

```swift
await store.send(.someAction) { $0.someValue = expected }

let provider = OpenTelemetry.instance.tracerProvider as! TracerProviderSdk
provider.forceFlush()

collector.assertSpanExists(named: "reducer/MyFeature")
collector.assertNoSpan(named: "reducer/OtherFeature")

let spans = collector.spans(named: "effect/fetchData")
#expect(!spans.isEmpty)
```

### Asserting on Metrics

Supply an `InMemoryMetricReader` when creating the test client:

```swift
let reader = InMemoryMetricReader()
let (client, collector) = TelemetryClient.test(metricReader: reader)
// ... exercise actions ...
// Query reader for metric data
```

### Serialization

Because `TelemetryClient.test()` registers global OTel providers, run
telemetry test suites serially:

```swift
@Suite("MyFeature Telemetry", .serialized)
struct MyFeatureTelemetryTests {
  // ...
}
```
