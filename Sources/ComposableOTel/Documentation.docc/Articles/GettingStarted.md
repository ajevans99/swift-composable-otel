# Getting Started

Add the current ComposableOTel instrumentation prototype to a TCA application.

## Install the package

Use the repository URL and current tagged release:

```swift
.package(
  url: "https://github.com/ajevans99/swift-composable-otel.git",
  from: "0.2.2"
)
```

Add `ComposableOTel` and `ComposableOTelExporters` to the application target.

## Bootstrap telemetry

Configure the OpenTelemetry SDK and inject the returned client into the root store:

```swift
import ComposableArchitecture
import ComposableOTel
import ComposableOTelExporters

let telemetry = TelemetryBootstrap.configure(
  serviceName: "my-app",
  environment: .debug
)

let store = Store(initialState: AppFeature.State()) {
  AppFeature()
} withDependencies: {
  $0.composableOTel = telemetry
}
```

Both bootstrap environments currently use stdout exporters. A
`.production(endpoint:headers:)` endpoint is not contacted, its headers are not used, and the
package does not provide a remote OTLP runtime yet.

## Instrument a reducer

```swift
@Reducer
struct GoalFeature {
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      // Feature logic.
    }
    .instrumented(name: "GoalFeature")
  }
}
```

Each action creates a span covering synchronous reducer execution. Action logging and metrics are
enabled by default. `stateDiffs: true` compares string snapshots only to set a changed boolean;
it does not export state values or a diff. The span ends before any returned effect executes.

## Trace an effect

Use `.tracedRun(name:)` to wrap the operation:

```swift
case .fetchGoals:
  return .tracedRun(name: "fetchGoals") { send in
    let goals = try await database.fetchAllGoals()
    await send(.goalsLoaded(goals))
  }
```

This records duration, completion, cancellation, and error telemetry. The current implementation
catches cancellation and other thrown errors rather than rethrowing them. Use `.traced()` only
when a start marker is sufficient; it does not observe the wrapped effect lifecycle.

## Trace a dependency call

```swift
let goals = try await tracedCall("goalDatabase", method: "fetchAll") {
  try await database.fetchAllGoals()
}
```

The throwing overload records an error and rethrows the original error. The nonthrowing overload
records successful call telemetry.

## Test instrumentation

```swift
import ComposableOTelTesting

let (telemetry, collectors) = TelemetryClient.test()
let store = TestStore(initialState: GoalFeature.State()) {
  GoalFeature()
} withDependencies: {
  $0.composableOTel = telemetry
}

await store.send(.refresh)
collectors.forceFlush()
collectors.spans.assertSpanExists(named: "reducer/GoalFeature")
```

The `ComposableOTelTesting` module documentation covers global-provider and serialization
constraints.
