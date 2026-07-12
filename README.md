# swift-composable-otel

OpenTelemetry instrumentation for
[The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

The package emits reducer, effect, and dependency spans; structured log records; and
metrics through the OpenTelemetry Swift API and SDK.

> [!IMPORTANT]
> The current tagged release is
> [`0.2.2`](https://github.com/ajevans99/swift-composable-otel/tree/0.2.2).
> It is a pre-1.0 instrumentation prototype, not a production OTLP runtime.
> Both `.debug` and `.production` use stdout exporters. The production endpoint and
> headers are currently ignored, and no telemetry is sent remotely.

## Installation

Add the package to `Package.swift`:

```swift
dependencies: [
  .package(
    url: "https://github.com/ajevans99/swift-composable-otel.git",
    from: "0.2.2"
  )
]
```

Add only the products required by each target:

```swift
dependencies: [
  // Core instrumentation APIs.
  .product(name: "ComposableOTel", package: "swift-composable-otel"),

  // SDK bootstrap and stdout exporters for an application target.
  .product(name: "ComposableOTelExporters", package: "swift-composable-otel"),

  // In-memory collectors and assertions for a test target.
  .product(name: "ComposableOTelTesting", package: "swift-composable-otel"),
]
```

## Quick start

Configure the SDK, retain the returned client in TCA dependencies, and instrument selected
reducers:

```swift
import ComposableArchitecture
import ComposableOTel
import ComposableOTelExporters
import SwiftUI

@main
struct MyApp: App {
  let store: StoreOf<AppFeature>

  init() {
    let telemetry = TelemetryBootstrap.configure(
      serviceName: "my-app",
      environment: .debug
    )
    self.store = Store(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.composableOTel = telemetry
    }
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: store)
    }
  }
}
```

```swift
@Reducer
struct MyFeature {
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      // Feature logic.
    }
    .instrumented(name: "MyFeature")
  }
}
```

Create a fully wrapped effect with `.tracedRun`:

```swift
return .tracedRun(name: "fetchData") { send in
  let data = try await client.fetch()
  await send(.dataLoaded(data))
}
```

Wrap dependency calls with `tracedCall`:

```swift
try await tracedCall("myClient", method: "fetch") {
  try await client.fetch()
}
```

## Current behavior

| Area | Release 0.2.2 behavior |
| --- | --- |
| Reducers | `.instrumented()` creates a synchronous span for reducer execution. It can emit an action log and records action-count and reducer-duration metrics. The span does not cover returned effects. |
| State | `stateDiffs: true` compares pre/post `String(describing:)` snapshots only to set `tca.state.changed`. State values and diffs are not exported. With the option disabled, the attribute is currently always `true`. |
| Effects | `.traced()` adds a merged start marker only. `.tracedRun()` records duration, completion, cancellation, and error signals. It catches cancellation and other thrown errors rather than rethrowing them. |
| Long-lived effects | `.tracedLongLivedRun()` emits separate start/end marker spans and metrics. Cancellation is treated as completion; other errors are logged and consumed. |
| Dependencies | `tracedCall` records a span, count, duration, and errors. Its throwing overload rethrows the original error. |
| Logs | Logs use the globally registered OpenTelemetry logger provider, even when called through an injected `TelemetryClient`. |
| Metrics | Reducer, effect, dependency, and active-effect instruments are registered lazily. Sampling does not suppress metrics. |
| Errors | `.redacted` is the default and omits `String(describing: error)` while retaining the error type. `SpanAttributeRedactor` is stored but is not applied by the current exporters. |
| Sampling | Parent-based trace ID ratio sampling defaults to `1.0` in debug and `0.1` in production. It applies to traces only. |

These semantics are documented so adopters can evaluate the prototype accurately. Context
propagation, effect semantics, injected logging, privacy enforcement, OTLP transport, buffering,
flush, and shutdown ownership belong to later roadmap work.

## Exporters

`TelemetryBootstrap.configure` currently behaves as follows:

| Environment | Traces | Metrics | Logs | Default trace ratio | Metric interval |
| --- | --- | --- | --- | --- | --- |
| `.debug` | stdout | stdout | stdout | `1.0` | 5 seconds |
| `.production` | stdout | stdout | stdout | `0.1` | 60 seconds |

The `.production(endpoint:headers:)` values reserve API shape for a later runtime. They do not
configure OTLP, HTTP, gRPC, TLS, authentication, retries, persistence, or application lifecycle
flushes in `0.2.2`.

## Testing

```swift
import ComposableOTelTesting

let (telemetry, collectors) = TelemetryClient.test()
let store = TestStore(initialState: MyFeature.State()) {
  MyFeature()
} withDependencies: {
  $0.composableOTel = telemetry
}

await store.send(.someAction)
collectors.forceFlush()
collectors.spans.assertSpanExists(named: "reducer/MyFeature")
```

`TelemetryClient.test()` registers global OpenTelemetry providers. Telemetry test suites must run
serially. The optional in-memory metric reader is provisional and is not part of the package's
current regression coverage.

## Compatibility

| Component | Supported posture |
| --- | --- |
| iOS | 17.0+; generic device build required in CI |
| macOS | 14.0+; package build and tests required in CI |
| watchOS | Unsupported today. The intended future floor is watchOS 10.0; see the named watchOS support gate in [SUPPORT.md](SUPPORT.md). |
| Swift | Swift tools 6.0 manifest; Xcode 16.3+ with Swift 6.x is the CI support baseline |
| Composable Architecture | `>= 1.17.0, < 2.0.0` |
| swift-dependencies | `>= 1.5.1, < 2.0.0` |
| OpenTelemetry Swift core | `>= 2.3.0, < 3.0.0` |

See [SUPPORT.md](SUPPORT.md) for platform and dependency policy, [CHANGELOG.md](CHANGELOG.md)
for release history, and [RELEASING.md](RELEASING.md) for versioning and release requirements.

## Products

| Product | Purpose |
| --- | --- |
| `ComposableOTel` | Core TCA instrumentation APIs and package metadata |
| `ComposableOTelExporters` | OpenTelemetry SDK bootstrap and stdout exporters |
| `ComposableOTelTesting` | In-memory span, log, and metric helpers |
