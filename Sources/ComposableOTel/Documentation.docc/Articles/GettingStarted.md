# Getting Started

Integrate OpenTelemetry into a TCA feature in under five minutes.

## Overview

This guide walks you through adding observability to an existing TCA
feature, from basic reducer instrumentation to full dependency tracing.

### Step 1: Bootstrap Telemetry

In your app's entry point, configure the SDK and inject the telemetry
client into your store's dependencies:

```swift
import ComposableOTel
import ComposableOTelExporters

@main
struct MyApp: App {
  let store: StoreOf<AppFeature>

  init() {
    let client = TelemetryBootstrap.configure(
      serviceName: "my-app",
      environment: .debug
    )

    self.store = Store(initialState: AppFeature.State()) {
      AppFeature()
    } withDependencies: {
      $0.composableOTel = client
    }
  }
}
```

### Step 2: Instrument a Reducer

Add `.instrumented()` to any reducer's body:

```swift
@Reducer
struct GoalFeature {
  // ...
  var body: some ReducerOf<Self> {
    Reduce { state, action in
      // ...
    }
    .instrumented(name: "GoalFeature")
  }
}
```

This automatically creates a span for every dispatched action, records
reducer duration, and increments action counters.

### Step 3: Trace Effects

Use `.tracedRun(name:)` instead of `.run` for effect lifecycle tracing:

```swift
case .fetchGoals:
  return .tracedRun(name: "fetchGoals") { send in
    let goals = try await database.fetchAllGoals()
    await send(.goalsLoaded(goals))
  }
```

### Step 4: Trace Dependency Calls

Wrap individual dependency methods with `tracedCall`:

```swift
extension GoalDatabaseClient: DependencyKey {
  static let liveValue = GoalDatabaseClient(
    fetchAll: {
      try await tracedCall("goalDB", method: "fetchAll") {
        try await db.fetchAllGoals()
      }
    }
  )
}
```

### Testing

In tests, use `TelemetryClient.test()` with `withDependencies`:

```swift
let (client, collector) = TelemetryClient.test()
let store = TestStore(initialState: MyFeature.State()) {
  MyFeature()
} withDependencies: {
  $0.composableOTel = client
}
// assert on collector.spans(named:)
```

See <doc:TestingGuide> for more detail.
