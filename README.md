# swift-composable-otel

Privacy-safe, bounded OpenTelemetry instrumentation for
[The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

> [!IMPORTANT]
> This revision prepares `0.4.0-rc.5`; publish that immutable tag only after its release pull request
> merges and hosted CI passes on the merge commit. The candidate remains pre-1.0. Production OTLP delivery is
> best-effort: iOS may suspend or terminate an application before queued telemetry is exported.

## Installation

```swift
dependencies: [
  .package(
    url: "https://github.com/ajevans99/swift-composable-otel.git",
    exact: "0.4.0-rc.5"
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

## Privacy-aware interpolated logs

`TelemetryClient.log` accepts OSLog-style interpolation without allowing private values into retained
telemetry:

```swift
let planID = response.planID
let outcome = TelemetryOutcome.success

telemetry.log(
  .info,
  "Plan \(planID) save finished with \(outcome, privacy: .public)"
)
```

Every unannotated interpolation is private. It becomes the fixed `<private>` token while
`TelemetryLogMessage` is constructed; the original value is not evaluated, described, or retained.
The exported record uses the stable `app.log` event name and carries a canonical literal template,
deterministic template identity, redacted rendered body, severity, typed public values, and active
trace/span context. Dynamic values therefore do not fragment template-based aggregation.

`.public` is deliberately unavailable for `String`, arbitrary `CustomStringConvertible`, `Error`,
`URL`, `TelemetryStringValue`, consumer-defined `TelemetryIdentifier` kinds, and other unconstrained
values. Approved overloads cover the package's concrete finite identifier domains,
`TelemetryOutcome`, `NavigationOperation`, `Bool`, and explicit `TelemetryLogInteger`,
`TelemetryLogDuration`, `TelemetryLogCountBucket`, and `TelemetryCorrelationID` wrappers. Identifier
values still pass through `TelemetrySchema`; valid but unregistered values become `other`.

Templates are limited to 512 UTF-8 bytes, rendered bodies to 1,024 UTF-8 bytes, interpolations to 16,
and public values to 8. An invalid message returns `.invalidMessage` without entering a logger,
observer, queue, exporter, or persistence path. `.recorded` means synchronous acceptance by the
configured pipeline, not successful remote delivery.

`TelemetryLoggingConfiguration` applies a minimum severity and deterministic sampling rate for each
supported severity. Sampling uses stable template or event identity, never a private value. Errors can
remain fully retained while reviewed informational templates are sampled.

Private rendering remains redacted by default. DEBUG builds expose one explicit overload that
evaluates private interpolation autoclosures only for an immediate renderer call:

```swift
#if DEBUG
telemetry.log(
  .info,
  "Plan \(planID) finished",
  debugConsole: .standardOutput
)
#endif
```

The ordinary retained record is still `Plan <private> finished`. The ephemeral body bypasses the SDK
logger, observers, testing collectors, tail buffers, queues, persistence, and OTLP. The overload is
absent from release builds.

## Registered process-session context

Hosts may register one deliberately small context at policy construction:

```swift
let policy = TelemetryPolicy(
  schema: schema,
  signals: signals,
  hostContext: TelemetryHostContext(
    processSessionID: .current,
    platform: .current,
    processKind: .application
  )
)
```

`TelemetryProcessSessionID.current` is an anonymous UUID generated once per process. It must not be
derived from an account, device, installation, or other persistent identity. After privacy validation,
the context is attached to spans and logs and follows reducer, effect, and dependency trace context
across async boundaries. It is excluded by construction from every package metric and registered
counter dimension.

## Typed exact-wire contracts

Applications that need stable external wire fields can register an immutable
`TelemetryContractCatalog` at bootstrap. Generic typed definitions cover custom spans, fixed EventName logs, bodyless operational events,
monotonic delta counters, and exact resources. Each definition fixes its name, field keys, scalar
types, finite enum/range values, optionality, conditional validation, unit/severity/body policy, and
series limit. Recording accepts only the registered definition and its typed payload:

```swift
let catalog = try TelemetryContractCatalog(
  contractVersion: .init(1),
  spans: [.init(flowSpan)],
  logs: [.init(flowCompletedLog)],
  operationalEvents: [.init(operationEvent)],
  counters: [.init(flowCounter)],
  resources: [.init(resourceDefinition)]
)
let policy = TelemetryPolicy(schema: schema, catalog: catalog)

try await telemetry.withSpan(flowSpan, payload: payload) {
  try telemetry.record(flowCompletedLog, payload: payload)
  telemetry.record(operationEvent, payload: payload)
  try telemetry.add(flowCounter, delta: .init(1), payload: payload)
}
```

Every registered signal injects one integer `telemetry.contract.version`. Record-time names,
attribute dictionaries, and raw SDK handles are not exposed. Counter dimensions must have finite
declared cardinality.

`TelemetryOperationalEventDefinition` is always bodyless with info severity. Its
`operationalEventsEnabled` control is independent from `logsEnabled`, so an application can record
registered operational events through the bounded log queue without enabling package-owned TCA
logs. Validation and queue insertion happen synchronously before `record` returns; export remains
bounded and asynchronous. Recording is nonthrowing and returns
`TelemetryOperationalEventRecordingResult`: `.recorded`, `.disabled`, `.dropped`, or
`.contractRejected`. Contract rejection fails closed and increments the runtime log dropped-item
diagnostic. Field extraction closures are nonthrowing; returning `nil` for a required field rejects
the payload.

`TelemetryRuntime.Configuration` accepts a finite `TelemetryDeploymentEnvironment`
(`development`, `test`, `staging`, or `production`) through `TelemetryResourceMode`. `.native`
preserves
the existing service, environment, Darwin, OpenTelemetry SDK, and package distribution attributes.
`.strict(resourceValue)` emits only the registered required keys plus contract version. Extra keys,
wrong scalar types, optional strict keys, a mismatched environment, and a resource from another
catalog are rejected before providers are created.

Registered bodyless logs preserve EventName, severity, `body == nil`, and typed fields. The supported
OpenTelemetry Swift log model has no severity-text field, so exact empty `severity_text` remains an
upstream limitation; this package does not add a raw OTLP bypass.

## Development quick start

The explicit debug bootstrap writes privacy-filtered telemetry to stdout:

```swift
let telemetry = try TelemetryBootstrap.configure(
  serviceName: "example-app",
  serviceVersion: "1.2.3",
  policy: policy
)

let store = Store(initialState: AppFeature.State()) {
  AppFeature()
} withDependencies: {
  $0.composableOTel = telemetry
}
```

Noisy or internal reducer actions can be omitted instead of aggregating to `other`:

```swift
AppFeature()
  .selectivelyInstrumented(feature: "library") { action in
    switch action {
    case .internalTimerTick:
      nil
    case .refreshButtonTapped:
      "refresh"
    }
  }
```

A `nil` mapping suppresses reducer, effect, dependency, log, and metric instrumentation originating
from that action. Existing `.instrumented(...)` behavior is unchanged.

`TelemetryBootstrap` is development-only. It has no production environment and cannot select a
remote or production stdout exporter.

### Observe sanitized telemetry on device

Debug tooling can inspect the same sampled signals without replacing stdout or OTLP export. Supply
standard OpenTelemetry exporters through `TelemetryObserverExporters`:

```swift
#if DEBUG
let inspector = InspectorTelemetry()
let exporterSet = inspector.makeExporters()
let observerExporters = TelemetryObserverExporters(
  spanExporters: [exporterSet.spanExporter],
  logRecordExporters: [exporterSet.logExporter],
  metricExporters: [exporterSet.metricExporter]
)
#else
let observerExporters = TelemetryObserverExporters()
#endif
```

Retain `inspector` in app-level state for its stores and UI. Each `exporterSet` is lifecycle-scoped:
pass it to exactly one `TelemetryBootstrap` or `TelemetryRuntime` lifetime and call
`inspector.makeExporters()` again for any separate configuration.

Pass the value to either local bootstrap:

```swift
let telemetry = try TelemetryBootstrap.configure(
  serviceName: "example-app",
  policy: policy,
  observerExporters: observerExporters
)
```

or production runtime configuration:

```swift
let configuration = TelemetryRuntime.Configuration(
  serviceName: "example-app",
  endpoints: endpoints,
  policy: policy,
  observerExporters: observerExporters
)
```

The package registers each observer independently behind its privacy boundary. Observers receive
only policy-sanitized, signal-enabled, sampled data; observer failure results do not suppress or
change stdout/OTLP export. Metric exporters receive native metrics and registered delta counters
through separate package-owned readers while the supplied exporter is flushed and shut down once.
Runtime force-flush, graceful shutdown, and terminal discard propagate to observer lifecycle;
discard does not flush. Like any completed export, data already accepted by an observer cannot be
retracted by `disableAndDiscardPending()`. Keep on-device stores bounded, apply host retention and
consent policy, and omit the inspector products from non-debug targets when they are not required.
Each supplied exporter is owned by exactly one bootstrap or runtime lifetime. Never reuse exporter
instances across separate configurations; create fresh exporter bundles that may share retained
stores.

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

Endpoints require HTTPS by default and must have a host with no embedded credentials, query, or
fragment. Invalid configuration throws before providers or exporters are created. The runtime never
accepts static header dictionaries. Its authenticator runs immediately before every attempt, so the
host can refresh short-lived credentials without placing a backend or vendor key in source, package
configuration, an application bundle, or persisted telemetry. Authorization is never persisted.

For a local simulator collector, plain HTTP requires an explicit, narrowly validated opt-in:

```swift
let configuration = TelemetryRuntime.Configuration(
  serviceName: "example-app",
  endpoints: OTLPEndpoints(baseURL: URL(string: "http://localhost:4318")!),
  endpointSecurity: .allowInsecureHTTPForLoopbackInDevelopmentOrTest,
  resourceMode: .native(environment: .development)
)
```

This policy permits HTTP only when the runtime resource environment is `development` or `test` and
every trace, metric, and log endpoint host is exactly `localhost`, an address in `127.0.0.0/8`, or
`::1`. Staging, production, LAN and other non-loopback hosts, mixed local/remote endpoint sets, and
alternate numeric host spellings remain rejected. HTTPS remains accepted in every environment.

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
| Encoded request queue | 256 batches; 64 KiB body ceiling; drop oldest |
| Request | 10-second timeout; gateway profiles can lower it |
| Retry | 4 total attempts; 1-to-30-second exponential backoff; 20% symmetric jitter |
| Metrics | 60-second periodic collection |
| Optional tail retention | 32 traces, 256 spans, 128 breadcrumbs, 512 KiB, 30 seconds |
| Flush | 10 seconds; 5 seconds when backgrounding |
| Persistence | Optional; 5 MiB and 24-hour maximum |

Retryable outcomes are transport timeouts and transient connectivity failures plus HTTP 408, 425,
429, 502, 503, and 504. A host-parsed numeric `Retry-After` on ``TelemetryHTTPResponse`` is honored
for retryable responses and clamped to the configured maximum backoff. Other HTTP responses,
including 401 and 413, and unclassified host errors are non-retryable.
`TelemetryRetryClassifyingError` lets a host transport or authenticator classify its own errors.
Retries stop at the attempt budget, observe cancellation, and reacquire authorization every time. A
custom transport can invalidate its host credential after a 401 before returning the response, so a
later independent request obtains fresh authorization.

`maximumEncodedRequestBytes` defaults to 64 KiB. Sanitized signal arrays are officially encoded and
recursively split in order before persistence/transport until every request fits. A single record
that cannot fit is dropped and increments both `oversizedRequests` and `droppedItems`. For a gateway
capped at 64 KiB, 50 signal items, and 5 seconds, the reviewed conservative profile uses 25-item
trace/log batches, a 64 KiB encoded ceiling, and a 5-second request timeout. Metric arrays are split
by `MetricData`; one metric containing too many points remains a single-record limit that the pilot
must prove or route elsewhere.

`maximumContractMetricPointsPerRequest` defaults to 50. Runtime creation rejects a registered custom
counter catalog whose declared maximum-series sum exceeds that independent point cap.

The package's official OTLP exporters do not enable compression, so the encoded ceiling bounds the
decoded protobuf body. A custom transport that adds compression remains responsible for enforcing
its compressed-body ceiling as well.

### Optional bounded tail promotion

Head sampling remains the default. To recover reviewed diagnostic traces without retaining all
telemetry, enable a bounded memory-only tail policy:

```swift
var configuration = TelemetryRuntime.Configuration(
  serviceName: "example-app",
  endpoints: endpoints,
  samplingRatio: 0.1,
  policy: policy
)
configuration.tailSampling = .enabled(
  try TelemetryTailSamplingPolicy(
    slowTraceThreshold: .seconds(2)
  )
)
```

When enabled, spans pass the package privacy boundary before a head-missed trace enters the tail
buffer. The package promotes the complete current root trace and correlated sanitized breadcrumbs on
an error span/log, the reviewed slow threshold, or
`TelemetryClient.triggerDiagnosticTracePromotion()` inside an active trace. Ordinary head-sampled
traces remain retained, so downstream sampling is additive rather than replaced.

Retention is bounded independently by trace count, span count, breadcrumb count, deterministic encoded
byte estimate, and age. Unpromoted entries remain memory-only and are discarded. If a correlated error
log cannot retain or enqueue its trace, its trace/span correlation is removed before export; an
exported error never points to a trace deliberately discarded by this runtime. Promotion does not
persist data directly: promoted signals first enter the existing bounded queues and privacy-safe OTLP
encoding path.

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

The maxima include the `other` aggregation value. Unknown instruments are dropped. Metric exemplars
are disabled by default. The opt-in `TelemetryMetricExemplarPolicy` retains at most one or two
exemplars per data point, requires valid SDK trace and span context, and removes every exemplar
attribute. It does not change metric attributes, host-context exclusion, or series cardinality.

See the DocC **Semantic Conventions and Stability** article for the complete field policy.

## Privacy boundary

`TelemetryBootstrap` and `TelemetryRuntime` apply allowlist-first policy before package-owned export:

- span names, attributes, events, links, status, and resources are sanitized;
- log bodies, attributes, event names, and resources are rebuilt from allowlists;
- metric views filter dimensions and define histograms; the exporter drops unknown instruments,
  sanitizes dimensions again, applies the default-off bounded exemplar policy, and refuses unsafe
  resources;
- instrumentation scope name/version are fixed; spans and metrics from unsafe scopes are dropped,
  and log scope metadata is rebuilt;
- resource fields are limited to bounded service name/version, fixed deployment environment,
  `os.type=darwin`, and fixed OpenTelemetry distribution/SDK identity.

The production runtime performs the same filtering before its span/log queues, applies metric views
before collection, and sanitizes every signal again before OTLP encoding, persistence, and network
delivery.

The normal package products do not expose arbitrary `info`, `error`, raw body, raw attribute,
tracer, logger, meter, sanitizer, processor, or view factories. The narrow observer surface accepts
standard exporters only after package privacy filtering. All other cross-target SDK wiring is a
Swift `package` implementation detail and is checked by symbol-graph plus expected-failure compile
gates.
Applications that integrate OpenTelemetry directly own that separate SDK trust boundary.

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
direct replacement. Migrate production composition to `TelemetryRuntime`; use
`TelemetryBootstrap.configure` only for explicit local stdout inspection.

## Testing

```swift
let reader = InMemoryMetricReader()
let (telemetry, collectors) = try TelemetryClient.test(
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
| watchOS | 9.0+; all library products compile in CI; contract/runtime APIs are supported |
| Swift | Swift tools 6.0 manifest; Xcode 16.3+ with Swift 6.x |
| Composable Architecture | `>= 1.25.0, < 2.0.0` |
| swift-dependencies | `>= 1.5.1, < 2.0.0` |
| OpenTelemetry Swift core | `>= 2.4.1, < 3.0.0` |
| OpenTelemetry Swift OTLP exporters | `>= 2.4.1, < 3.0.0` |
| swift-sharing compatibility constraint | `== 2.8.2` |

See [SUPPORT.md](SUPPORT.md) and [RELEASING.md](RELEASING.md).

## Release evidence

The 0.4.0-rc.5 package quality layer includes:

- externally meaningful tests plus concurrency stress and a macOS Thread Sanitizer lane;
- target-specific coverage floors of 90% core, 80% exporters, 50% testing utilities, and 80% for
  `TelemetryRuntime*` delivery paths;
- a checked public API baseline and an explicit semantic-convention review lock;
- release benchmarks for reducers, effects, dependencies, event creation, logs, metrics,
  sampled/unsampled spans, state tokens, runtime configuration/startup, tail-buffer memory, batching,
  and queue pressure; and
- current iOS simulator tests, generic iOS product builds, minimum/latest dependency endpoints, and
  all-product DocC builds.

See [RELEASE_NOTES.md](RELEASE_NOTES.md), [MIGRATION.md](MIGRATION.md),
[PERFORMANCE.md](PERFORMANCE.md), [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and the
[consumer pilot evidence contract](PILOT.md). This is a pre-1.0 release. External production-like
consumer evidence and repository protection remain accepted residual risks for 0.4.0-rc.5 and required
no-go items for 1.0.

## License

swift-composable-otel is available under the [MIT License](LICENSE), SPDX identifier `MIT`.
