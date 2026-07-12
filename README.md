# swift-composable-otel

Privacy-safe, bounded OpenTelemetry instrumentation for
[The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

> [!IMPORTANT]
> The current tagged release is
> [`0.2.2`](https://github.com/ajevans99/swift-composable-otel/tree/0.2.2).
> The behavior documented below is unreleased and remains a pre-1.0 instrumentation prototype, not
> a production OTLP runtime. Both `.debug` and `.production` use stdout exporters. Production
> endpoint and header values are ignored, and no telemetry is sent remotely.

## Installation

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
.product(name: "ComposableOTel", package: "swift-composable-otel")
.product(name: "ComposableOTelExporters", package: "swift-composable-otel")
.product(name: "ComposableOTelTesting", package: "swift-composable-otel")
```

## Bounded schema

Applications explicitly declare the finite identifiers they permit:

```swift
let schema = try! TelemetrySchema(
  features: ["library"],
  actions: ["refresh", "book-selected", "response-received"],
  effects: ["fetch-books"],
  dependencies: ["book-client"],
  operations: ["fetch"],
  routes: ["book-detail"],
  errorTypes: ["network-error"],
  errorCategories: ["network"],
  errorCodes: ["unavailable"],
  services: ["example-app"],
  serviceVersions: ["1.2.3"]
)

let policy = TelemetryPolicy(
  schema: schema,
  classifyError: { _ in
    TelemetryErrorMetadata(
      type: "network-error",
      category: "network",
      code: "unavailable",
      retryable: true
    )
  }
)
```

`FeatureID`, `ActionID`, `EffectID`, `DependencyID`, `OperationID`, `RouteID`, error IDs,
`ServiceID`, and `ServiceVersionID` are distinct types. General identifiers accept 1 through 48
lowercase ASCII characters using letters, digits, `.`, `_`, or `-` and require a leading letter.
Service versions additionally accept a leading digit plus uppercase letters and `+` for bounded
semantic-version prerelease/build syntax. Invalid dynamic input is rejected. Valid identifiers not
present in the configured schema deterministically aggregate to `other`; raw SDK values that are
malformed also aggregate to `other`.

Schema construction rejects limits above 32 features, 128 actions, 64 effects, 64 dependencies,
128 operations, 64 routes, 32 error types, 32 error categories, 64 error codes, 8 services, or 16
service versions. Rejected values are never printed.

## Quick start

Bootstrap once and inject the returned client:

```swift
let telemetry = TelemetryBootstrap.configure(
  serviceName: "example-app",
  serviceVersion: "1.2.3",
  environment: .debug,
  policy: policy
)

let store = Store(initialState: AppFeature.State()) {
  AppFeature()
} withDependencies: {
  $0.composableOTel = telemetry
}
```

Instrument a reducer without reflecting actions:

```swift
Reduce { state, action in
  // Feature logic.
}
.instrumented(
  feature: "library",
  action: { action in
    switch action {
    case .refresh: "refresh"
    case .bookSelected: "book-selected"
    case .responseReceived: "response-received"
    }
  },
  stateChangeToken: { StateChangeToken($0.revision) }
)
```

The optional state token is compared before and after synchronous reduction but is never exported.
If it is omitted, `tca.state.changed` is omitted. The package never calls
`String(describing:)` on actions or state and never materializes state descriptions.

Trace effects and dependency operations with typed IDs:

```swift
return .tracedRun(effect: "fetch-books") { send in
  let books = try await tracedCall(
    dependency: "book-client",
    operation: "fetch"
  ) {
    try await client.fetch()
  }
  await send(.responseReceived(books))
}
```

Record route names without parameters:

```swift
telemetry.recordNavigation(.push, route: "book-detail")
```

## Signal controls

Traces, metrics, and logs are independent. Action and navigation logs are disabled by default:

```swift
let signals = TelemetrySignalConfiguration(
  tracesEnabled: true,
  metricsEnabled: true,
  logsEnabled: false
)
let policy = TelemetryPolicy(schema: schema, signals: signals)
```

Trace sampling applies only to traces. Disabling or sampling traces does not suppress metrics or
logs, and disabling logs does not suppress error status, events, or metrics.

## Semantic conventions

Package-owned span names never contain identifiers:

| Span | Bounded attributes |
| --- | --- |
| `tca.reducer` | `tca.feature.name`, `tca.action.name`, optional `tca.state.changed` |
| `tca.effect` | `tca.effect.name`, `tca.effect.long_lived`, `tca.effect.outcome` |
| `tca.dependency` | `tca.dependency.name`, `tca.operation.name` |
| `tca.navigation` | `tca.navigation.operation`, `tca.navigation.route` |

Effect outcomes are exactly `success`, `cancelled`, or `error`. Package event names and log bodies
are fixed constants. Error status is rewritten to generic text before export. Production-safe error
fields are bounded type, category, optional code, handled, and retryable values. Raw error
descriptions, localized text, backend bodies, stack traces, URLs, payloads, and state/action values
are not package fields.

Package metrics use explicit descriptions, units, SDK views, and export-time dimension filtering:

| Metrics | Unit | Dimensions | Maximum series |
| --- | --- | --- | --- |
| `tca.actions.dispatched`, `tca.reducer.duration` | `{action}`, `ms` | feature, action | 4,257 |
| Effect start/terminal/duration/active metrics | `{effect}`, `ms` | effect, long-lived | 130 each |
| Dependency call/error/duration metrics | `{call}`, `ms` | dependency, operation | 8,385 each |
| `tca.navigation.transitions` | `{transition}` | operation, route | 260 |

The maxima include the `other` aggregation value. Unknown instruments are dropped. Metric
exemplars are removed by the package exporter boundary so filtered attributes cannot reappear.

See the DocC **Semantic Conventions and Stability** article for the complete field policy.

## Privacy boundary

`TelemetryBootstrap` applies allowlist-first policy before stdout export:

- span names, attributes, events, links, status, and resources are sanitized;
- log bodies, attributes, event names, and resources are rebuilt from allowlists;
- metric views filter dimensions and define histograms; the exporter drops unknown instruments,
  sanitizes dimensions again, removes exemplars, and refuses unsafe resources;
- instrumentation scope name/version are fixed; spans and metrics from unsafe scopes are dropped,
  and log scope metadata is rebuilt;
- resource fields are limited to bounded service name/version, fixed deployment environment,
  `os.type=darwin`, and fixed OpenTelemetry distribution/SDK identity.

The package no longer exposes arbitrary `info`, `error`, raw body, raw attribute, tracer, logger, or
meter convenience APIs. `TelemetryClient.unsafeCustomSDK` and
`MetricInstruments.unsafeCustomSDK` are intentionally named trust boundaries. A custom SDK,
processor, reader, or exporter can bypass package enforcement unless it uses
`PrivacyPreservingSpanExporter`, `PrivacyPreservingLogRecordExporter`,
`PrivacyPreservingMetricExporter`, `ComposableOTelMetricConfiguration`, and a resource sanitized
by the same `TelemetryPolicy`.

The package does not offer a raw-payload development mode. Applications that create raw
OpenTelemetry data directly own its classification, consent, redaction, retention, and exporter
policy.

## Context and lifecycle semantics

Reducer spans cover synchronous reduction. Traced effects created during reduction capture the
reducer span as their explicit parent; the reducer span ends before effect execution. Effect spans
remain task-locally active across suspension and inherited child tasks. Detached tasks do not
inherit that context.

One-shot and long-lived effects emit exactly one terminal outcome. Errors and cancellation are
recorded and rethrown to TCA's normal handling. Active-effect increments and decrements are paired
by structured cleanup.

## Exporters

`TelemetryBootstrap.configure` is thread-safe and first-configuration-wins idempotent. It returns
an isolated package client and does not replace OpenTelemetry process globals, so unrelated SDK
traffic is not rewritten or dropped by this package policy.

| Environment | Export destination | Default trace ratio | Metric interval |
| --- | --- | --- | --- |
| `.debug` | stdout | `1.0` | 5 seconds |
| `.production` | stdout | `0.1` | 60 seconds |

`.production(endpoint:headers:)` does not configure OTLP, HTTP, gRPC, TLS, authentication, retry,
persistence, lifecycle flush, or remote transport. Those remain issue #5 work.

## Testing

```swift
let reader = InMemoryMetricReader()
let (telemetry, collectors) = TelemetryClient.test(
  metricReader: reader,
  policy: policy
)

let store = TestStore(initialState: AppFeature.State()) {
  AppFeature()
} withDependencies: {
  $0.composableOTel = telemetry
}

await store.send(.refresh)
collectors.forceFlush()
collectors.spans.assertSpanExists(named: "tca.reducer")
```

Test clients own isolated providers and install the same span/log privacy wrappers and metric views
as bootstrap. They do not replace process globals.

## Compatibility

| Component | Supported posture |
| --- | --- |
| iOS | 17.0+; generic device build required in CI |
| macOS | 14.0+; package build and tests required in CI |
| watchOS | Unsupported; the intended future floor is watchOS 10.0 and remains gated by [SUPPORT.md](SUPPORT.md) |
| Swift | Swift tools 6.0 manifest; Xcode 16.3+ with Swift 6.x |
| Composable Architecture | `>= 1.25.0, < 2.0.0` |
| swift-dependencies | `>= 1.5.1, < 2.0.0` |
| OpenTelemetry Swift core | `>= 2.4.1, < 3.0.0` |
| swift-sharing compatibility constraint | `== 2.8.2` |

See [SUPPORT.md](SUPPORT.md), [CHANGELOG.md](CHANGELOG.md), and
[RELEASING.md](RELEASING.md).

## License

swift-composable-otel is available under the [MIT License](LICENSE), SPDX identifier `MIT`.
