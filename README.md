# swift-composable-otel

Privacy-safe, bounded OpenTelemetry instrumentation for
[The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

> [!IMPORTANT]
> The current tagged release is
> [`0.2.2`](https://github.com/ajevans99/swift-composable-otel/tree/0.2.2).
> The behavior documented below is unreleased and remains pre-1.0. Production OTLP delivery is
> best-effort: iOS may suspend or terminate an application before queued telemetry is exported.

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

## Development quick start

The explicit debug bootstrap writes privacy-filtered telemetry to stdout:

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

`TelemetryBootstrap` is development-only. It has no production environment and cannot select a
remote or production stdout exporter.

## Production OTLP/HTTP runtime

Create and retain one `TelemetryRuntime` at the application composition root. Inject only its
feature-facing `client`:

```swift
let runtime = try TelemetryRuntime(
  configuration: .init(
    serviceName: "example-app",
    serviceVersion: "1.2.3",
    endpoints: OTLPEndpoints(
      baseURL: URL(string: "https://telemetry.example.com/otlp")!
    ),
    policy: policy,
    persistence: .init(
      directory: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("TelemetrySpool")
    )
  ),
  authenticator: .init { request in
    var request = request
    let credential = try await appCredentialProvider.shortLivedCredential()
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    return request
  }
)

let store = Store(initialState: AppFeature.State()) {
  AppFeature()
} withDependencies: {
  $0.composableOTel = runtime.client
}
```

Production endpoints must be HTTPS URLs with a host and no embedded credentials, query, or
fragment. Invalid configuration throws before providers or exporters are created. The runtime never
accepts static header dictionaries. Its authenticator runs immediately before every attempt, so the
host can refresh short-lived credentials without placing a backend or vendor key in source, package
configuration, an application bundle, or persisted telemetry. Authorization is never persisted.

A recommended deployment sends OTLP/HTTP to an application-owned ingestion gateway. The app obtains
a narrow, expiring credential from its backend, optionally after App Attest or DeviceCheck
verification; the gateway authenticates, rate-limits, and forwards to the selected observability
backend. The package does not implement or couple to that backend, gateway, credential service, or
vendor.

### Bounded delivery

`TelemetryRuntime` owns isolated tracer, meter, and logger providers; privacy processors; bounded
span and log queues; metric reader; official OTLP/HTTP encoders; request delivery; persistence; and
lifecycle state. Export work runs away from the main actor and reducer execution.

Default limits are finite and configurable:

| Boundary | Default |
| --- | --- |
| Span/log queue | 2,048 items; 512-item batch; 5-second schedule; drop oldest |
| Encoded request queue | 256 batches; drop oldest |
| Request | 10-second timeout |
| Retry | 4 total attempts; 1-to-30-second exponential backoff; 20% symmetric jitter |
| Metrics | 60-second periodic collection |
| Flush | 10 seconds; 5 seconds when backgrounding |
| Persistence | Optional; 5 MiB and 24-hour maximum |

Retryable outcomes are transport timeouts and transient connectivity failures plus HTTP 408, 425,
429, 502, 503, and 504. Other HTTP responses and unclassified host errors are non-retryable.
`TelemetryRetryClassifyingError` lets a host transport or authenticator classify its own errors.
Retries stop at the attempt budget, observe cancellation, and reacquire authorization every time.

`setExportCondition(_:)` accepts reachability or policy hints. `.unavailable` pauses new attempts;
`.available` and `.constrained` permit them. Reachability never proves that DNS, TLS, authentication,
the gateway, or the backend will accept a request.

### Optional persistence

Persistence stores only allowlisted telemetry after span/log processors or metric views and the
export privacy boundary have sanitized it. Authorization, cookies, and arbitrary request headers are
never written. Each encoded OTLP batch uses an atomic file, bounded age and total bytes, backup
exclusion, and the configured Apple file-protection class. The default
`completeUntilFirstUserAuthentication` posture permits post-first-unlock background access.
Corrupt, unsupported, expired, or oversized records are removed deterministically; valid records are
recovered on the next launch.

Persistence improves retry opportunities but does not guarantee delivery. Files can be lost through
application deletion, storage pressure, protection-state constraints, or host cleanup.

### Lifecycle and diagnostics

Forward host lifecycle events without importing UIKit into feature code:

```swift
await runtime.applicationDidBecomeActive()

let result = await runtime.applicationDidEnterBackground(
  remainingTime: hostRemainingBudget
)

let shutdown = await runtime.shutdown(timeout: .seconds(5))
```

The host owns any `UIApplication.beginBackgroundTask`, `BGTaskScheduler`, SwiftUI scene-phase, or
macOS termination integration and passes only the available time budget. `forceFlush` and `shutdown`
return per-signal success, failure, timeout, pending, and drop information. Shutdown is idempotent;
persisted timed-out batches remain for relaunch, while memory-only batches are dropped.

For consent revocation or a privacy kill switch, first swap the host facade or TCA dependency to
`TelemetryClient.noop`, then invoke the terminal discard operation:

```swift
telemetryFacade.replaceClient(with: .noop)
let discard = await runtime.disableAndDiscardPending()
```

`disableAndDiscardPending()` never flushes. It permanently stops this runtime from accepting signal
data, cancels delivery and retry work, deletes queued and persisted telemetry, shuts down its
providers, and cannot be reversed by an active-lifecycle or export-condition update. Concurrent
calls share one idempotent result. A filesystem deletion failure is isolated into the structured
result and diagnostics; a later call retries the deletion. Graceful `shutdown()` intentionally keeps
its separate retain-for-relaunch behavior.

The synchronous `diagnostics` snapshot reports queue depth, drops, persisted items/bytes, attempts,
successes, retryable and non-retryable failures, last success, corruption recovery, and flush
and discard outcomes. An optional structured diagnostic handler receives the same bounded categories
directly, not through OpenTelemetry, preventing recursive exporter telemetry.

> [!WARNING]
> Mobile delivery is best-effort. A bounded background flush may help while execution time remains,
> but the package cannot export after suspension, force-quit, crash, device shutdown, or process
> termination and does not promise delivery before any of those events.

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

`TelemetryBootstrap` and `TelemetryRuntime` apply allowlist-first policy before package-owned export:

- span names, attributes, events, links, status, and resources are sanitized;
- log bodies, attributes, event names, and resources are rebuilt from allowlists;
- metric views filter dimensions and define histograms; the exporter drops unknown instruments,
  sanitizes dimensions again, removes exemplars, and refuses unsafe resources;
- instrumentation scope name/version are fixed; spans and metrics from unsafe scopes are dropped,
  and log scope metadata is rebuilt;
- resource fields are limited to bounded service name/version, fixed deployment environment,
  `os.type=darwin`, and fixed OpenTelemetry distribution/SDK identity.

The production runtime performs the same filtering before its span/log queues, applies metric views
before collection, and sanitizes every signal again before OTLP encoding, persistence, and network
delivery.

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

`TelemetryBootstrap.configure` is a thread-safe, first-configuration-wins debug helper.
`TelemetryRuntime` is the independently owned production path. Neither replaces OpenTelemetry
process globals, so unrelated SDK traffic is not rewritten or dropped by this package policy.

| Runtime | Export destination | Default trace ratio | Metric interval |
| --- | --- | --- | --- |
| `TelemetryBootstrap` | development stdout | `1.0` | 5 seconds |
| `TelemetryRuntime` | validated OTLP/HTTP over TLS | `0.1` | 60 seconds |

The removed `.production(endpoint:headers:)` bootstrap placeholder never sent remotely and has no
direct replacement. Migrate production composition to `TelemetryRuntime`; keep `.debug` only for
explicit local stdout inspection.

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
| OpenTelemetry Swift OTLP exporters | `>= 2.4.1, < 3.0.0` |
| swift-sharing compatibility constraint | `== 2.8.2` |

See [SUPPORT.md](SUPPORT.md), [CHANGELOG.md](CHANGELOG.md), and
[RELEASING.md](RELEASING.md).

## Release evidence

The unreleased package quality layer includes:

- 68 externally meaningful tests plus concurrency stress and a macOS Thread Sanitizer lane;
- target-specific coverage floors of 90% core, 80% exporters, 50% testing utilities, and 80% for
  `TelemetryRuntime*` delivery paths;
- a checked public API baseline and an explicit semantic-convention review lock;
- release benchmarks for reducers, effects, dependencies, logs, metrics, sampled/unsampled spans,
  state tokens, batching, memory, and queue pressure; and
- current iOS simulator tests, generic iOS product builds, minimum/latest dependency endpoints, and
  all-product DocC builds.

See [RELEASE_NOTES.md](RELEASE_NOTES.md), [MIGRATION.md](MIGRATION.md),
[PERFORMANCE.md](PERFORMANCE.md), [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and the
[consumer pilot evidence contract](PILOT.md). No 1.0 tag or release exists. The external pilot and
repository protection evidence remain required no-go items.

## License

swift-composable-otel is available under the [MIT License](LICENSE), SPDX identifier `MIT`.
