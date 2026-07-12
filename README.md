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

Configure the SDK once, retain the returned client in TCA dependencies, and instrument selected
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

The table describes the unreleased behavior on `main`; the tagged `0.2.2` release predates these
corrections.

| Area | Current behavior |
| --- | --- |
| Reducers | `.instrumented()` uses closure-based task-local activation for synchronous reduction. Traced effects created during reduction capture the reducer span as their explicit parent; the reducer span still ends before effect execution. |
| State | `stateDiffs: true` compares pre/post `String(describing:)` snapshots only to set `tca.state.changed`. State values and diffs are not exported. With the option disabled, the attribute is currently always `true`. |
| Effects | `.tracedRun()` uses one task-locally active span across suspension and inherited child tasks. It records exactly one `success`, `cancelled`, or `error` outcome and rethrows failures and cancellation to TCA's normal handling. |
| Effect markers | `.traceStart()` adds only a merged initiation marker. The old `.traced()` spelling is deprecated because it never observed the wrapped effect lifecycle. |
| Long-lived effects | `.tracedLongLivedRun()` uses one lifecycle span. Normal stream completion is `success`; cancellation and errors are distinct outcomes and are rethrown. |
| Dependencies | `tracedCall` uses closure-based task-local activation and records a span, count, duration, and errors. Its throwing overload rethrows the original error. |
| Logs | `TelemetryClient` stores an injected logger. Log calls never re-resolve the mutable global logger provider. |
| Metrics | Reducer, effect, dependency, and active-effect instruments are registered lazily. Effect terminal counters are mutually exclusive, and active-effect increments/decrements are paired by structured cleanup. Sampling does not suppress metrics. |
| Errors | `.redacted` is the default and omits `String(describing: error)` while retaining the error type. `SpanAttributeRedactor` is stored but is not applied by the current exporters. |
| Sampling | Parent-based trace ID ratio sampling defaults to `1.0` in debug and `0.1` in production. It applies to traces only. |

Effects constructed during instrumented reduction explicitly inherit that reducer span. Effects
constructed elsewhere intentionally start a root trace. While a traced operation runs, normal
Swift child tasks inherit its OpenTelemetry task-local context; detached tasks do not.

Tracing does not convert thrown failures into success. Handle and map a failure to an action inside
the host operation when that is desired. Otherwise the error is rethrown to TCA, which reports an
unhandled non-cancellation `Effect.run` error according to its standard behavior. TCA treats
rethrowing `CancellationError` as normal effect cancellation.

## Exporters

`TelemetryBootstrap.configure` is thread-safe and process-idempotent. The first call owns the
process-wide OpenTelemetry providers and configuration; repeated or concurrent calls return the
same cached `TelemetryClient` without registering providers again. Accessing the default no-op
dependency before bootstrap does not snapshot or poison the later configured client.
OpenTelemetry exposes its compatibility globals through separate setters, so call bootstrap before
starting code that reads those globals. Normal ComposableOTel paths use the returned client only.

Bootstrap currently behaves as follows:

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

`TelemetryClient.test()` owns its tracer, meter, and logger providers without replacing
`OpenTelemetry.instance` globals, so independently injected test clients remain isolated under
concurrency. `configureTestTelemetry` is the deprecated global-provider compatibility helper and
still requires serialized use. The optional metric reader covers effect counters and balanced
active-effect accounting in the package regression suite.

## Compatibility

| Component | Supported posture |
| --- | --- |
| iOS | 17.0+; generic device build required in CI |
| macOS | 14.0+; package build and tests required in CI |
| watchOS | Unsupported today. The intended future floor is watchOS 10.0; see the named watchOS support gate in [SUPPORT.md](SUPPORT.md). |
| Swift | Swift tools 6.0 manifest; Xcode 16.3+ with Swift 6.x is the CI support baseline |
| Composable Architecture | `>= 1.25.0, < 2.0.0` |
| swift-dependencies | `>= 1.5.1, < 2.0.0` |
| OpenTelemetry Swift core | `>= 2.4.1, < 3.0.0` |

See [SUPPORT.md](SUPPORT.md) for platform and dependency policy, [CHANGELOG.md](CHANGELOG.md)
for release history, and [RELEASING.md](RELEASING.md) for versioning and release requirements.

## Products

| Product | Purpose |
| --- | --- |
| `ComposableOTel` | Core TCA instrumentation APIs and package metadata |
| `ComposableOTelExporters` | OpenTelemetry SDK bootstrap and stdout exporters |
| `ComposableOTelTesting` | In-memory span, log, and metric helpers |

## License

swift-composable-otel is available under the [MIT License](LICENSE), SPDX identifier `MIT`.
