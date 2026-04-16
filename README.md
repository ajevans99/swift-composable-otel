# swift-composable-otel

OpenTelemetry instrumentation for [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

Provides traces, metrics, and structured logs for TCA reducers, effects, and dependencies using the [OpenTelemetry](https://opentelemetry.io) standard.

## Installation

Add to your `Package.swift`:

```swift
.package(url: "https://github.com/your-org/swift-composable-otel", from: "0.1.0")
```

Then add the products you need:

```swift
// Core instrumentation (required)
.product(name: "ComposableOTel", package: "swift-composable-otel")

// Exporter configuration (for app bootstrap)
.product(name: "ComposableOTelExporters", package: "swift-composable-otel")

// Test utilities (for test targets only)
.product(name: "ComposableOTelTesting", package: "swift-composable-otel")
```

## Quick Start

### Bootstrap

```swift
import ComposableOTelExporters

@main
struct MyApp: App {
  init() {
    TelemetryBootstrap.configure(
      serviceName: "my-app",
      environment: .debug
    )
  }
}
```

### Instrument Reducers

```swift
import ComposableOTel

@Reducer struct MyFeature {
  var body: some Reducer<State, Action> {
    Reduce { state, action in
      // your logic
    }
    .instrumented()
  }
}
```

### Trace Effects

```swift
return .run(name: "fetchData") { send in
  let data = try await client.fetch()
  await send(.dataLoaded(data))
}
.traced()
```

### Trace Dependencies

```swift
try await tracedCall("myClient", method: "fetch") {
  try await self.client.fetch()
}
```

## Targets

| Target | Purpose | Dependencies |
|--------|---------|-------------|
| `ComposableOTel` | Core instrumentation APIs | OpenTelemetryApi, ComposableArchitecture |
| `ComposableOTelExporters` | Bootstrap and export config | Core + OpenTelemetrySdk, StdoutExporter |
| `ComposableOTelTesting` | Test assertion helpers | Core + OpenTelemetrySdk |

## Compatibility

- iOS 17.0+, macOS 14.0+
- Swift 6.0
- swift-composable-architecture 1.17+
- opentelemetry-swift-core 2.3+
