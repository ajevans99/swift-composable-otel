# Getting Started

Configure a finite telemetry schema, inject a client, and instrument selected TCA work.

## Install

```swift
.package(
  url: "https://github.com/ajevans99/swift-composable-otel.git",
  from: "0.2.2"
)
```

Add `ComposableOTel` and `ComposableOTelExporters` to the application target.

## Define policy

```swift
let schema = try! TelemetrySchema(
  features: ["library"],
  actions: ["refresh", "response-received"],
  effects: ["fetch-books"],
  dependencies: ["book-client"],
  operations: ["fetch"],
  routes: ["book-detail"],
  services: ["example-app"]
)

let policy = TelemetryPolicy(schema: schema)
```

Identifiers use lowercase bounded names, not user values, IDs, URLs, titles, notes, search text, or
route parameters. Values absent from the schema aggregate to `other`.

## Bootstrap once

```swift
let telemetry = TelemetryBootstrap.configure(
  serviceName: "example-app",
  environment: .debug,
  policy: policy
)

let store = Store(initialState: AppFeature.State()) {
  AppFeature()
} withDependencies: {
  $0.composableOTel = telemetry
}
```

Bootstrap is thread-safe and first-configuration-wins idempotent. It does not replace process-global
OpenTelemetry providers. Both environments use privacy-preserving stdout exporters. Production
endpoint and headers are unused, and the package does not provide remote OTLP transport.

## Instrument a reducer

```swift
Reduce { state, action in
  // Feature logic.
}
.instrumented(
  feature: "library",
  action: { action in
    switch action {
    case .refresh: "refresh"
    case .responseReceived: "response-received"
    }
  },
  stateChangeToken: { StateChangeToken($0.revision) }
)
```

The action mapper replaces reflection. Associated values and custom descriptions are never read.
The optional state token is compared but never exported; no state description is created.

## Trace effects and dependencies

```swift
return .tracedRun(effect: "fetch-books") { send in
  let books = try await tracedCall(
    dependency: "book-client",
    operation: "fetch"
  ) {
    try await database.fetchAll()
  }
  await send(.responseReceived(books))
}
```

Effect failures and cancellation are recorded and rethrown. Reducer-to-effect explicit parenting
and task-local propagation across suspension and inherited child tasks are preserved.

## Configure signals

```swift
let policy = TelemetryPolicy(
  schema: schema,
  signals: TelemetrySignalConfiguration(
    tracesEnabled: true,
    metricsEnabled: true,
    logsEnabled: false
  )
)
```

Each signal is independent. Logs are disabled by default, and trace sampling never suppresses
metrics.

## Test

```swift
let (telemetry, collectors) = TelemetryClient.test(policy: policy)
// Inject, exercise the feature, then:
collectors.forceFlush()
collectors.spans.assertSpanExists(named: "tca.reducer")
```

Read <doc:SemanticConventions> before adding identifiers or custom SDK integration.
