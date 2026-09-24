# Migrating from 0.4.0 to 0.5.0

0.5.0 is additive at the source level: every 0.4.0 public API, including `.instrumented`,
`.selectivelyInstrumented`, `.tracedRun`, `.tracedLongLivedRun`, `traceStart`, `tracedCall`,
`recordNavigation`, typed contracts, and interpolated logs, still compiles unchanged. Update the
requirement to `from: "0.5.0"`.

## Adopt the new APIs

| Goal | 0.5.0 API |
| --- | --- |
| Instrument every endpoint of a dependency client consistently | `TelemetryDependencyInstrumentation(_:)` with `instrument(_:_:)`, `instrumentStream(_:_:)`, or `call(_:_:)` |
| Common operation names | `OperationID.fetch`, `.save`, `.delete`, `.stream`, `.sync`, `.authorize` |
| Start work with no reducer parent | `withTracedRootFlow(feature:flow:operation:)` |
| Deliberately start a new trace from a reducer | `Effect.tracedRootRun(feature:effect:priority:operation:)` |
| Match lifecycle logs by name | `ComposableOTelSemantics.LogEvents` |

Register every new effect, flow, dependency, and operation name in `TelemetrySchema`. Unregistered
names aggregate as `other`. Replace hand-written per-call `tracedCall` wrappers in a client's
`liveValue` with one `TelemetryDependencyInstrumentation` so names and outcomes stay consistent.

## Behavior changes

These changes affect only exported telemetry, not feature behavior:

| 0.4.0 behavior | 0.5.0 behavior | Action |
| --- | --- | --- |
| With logs enabled, effects and dependencies logged only failures | Effects log `tca.effect.started` and one terminal log; dependencies log `tca.dependency.started` and one terminal log | Filter by `event.name` in dashboards; lower `infoSampling` if volume matters |
| Package logs had no `event.name` | Every lifecycle log sets a stable `event.name` | Prefer `event.name` over body text in queries |
| The action-dispatched log had no trace correlation | It carries the reducer span's trace and span IDs | None |
| Navigation spans were parentless | Navigation spans are children of the active reducer, effect, or dependency span | Update trace-shape assertions |
| Effect and dependency spans had no feature | They carry `tca.feature.name` from the reducer or root flow | None; metric dimensions are unchanged |
| A dependency throwing `CancellationError` was an error: error span status, `tca.dependencies.errored`, `Dependency call failed` log | Outcome `cancelled`, unset span status, `tca.dependency.cancelled = true`, `tca.dependency.completed` log, not counted as errored | Update alerts that treated cancellation as failure |
| Fractional log sampling was keyed by template or event identity and re-evaluated at export | Decided once at emission, keyed by process session plus per-record identity (event name, span, sequence); the export boundary applies only the severity filter | None with the default `.always` rates. With fractional rates, records of one event are now sampled independently rather than all-or-nothing |

The fractional-sampling change applies to lifecycle logs, privacy-aware `app.log` records, and
registered catalog logs alike. `TelemetryLoggingConfiguration` and its `deterministicSeed` are unchanged.

# Migrating from 0.2.2 to 0.3.0

The changes below describe migration from `0.2.2` to the pre-1.0 `0.3.0` release.

| Previous API or behavior | 0.3.0 replacement |
| --- | --- |
| Reflection-derived reducer and action names | Pass typed `feature:` and `action:` values to `.instrumented(...)`. |
| State description comparison | Supply an optional opaque `StateChangeToken`; omit it when no non-sensitive token exists. |
| String effect and dependency names | Use `EffectID`, `DependencyID`, and `OperationID` values present in `TelemetrySchema`. |
| `.traced()` marker | Use `.traceStart(effect:)`; use `.tracedRun` or `.tracedLongLivedRun` for lifecycle outcomes. |
| `configureTestTelemetry` | Use `try TelemetryClient.test(metricReader:policy:)` and inject the returned client. |
| `ErrorDetailPolicy` and `SpanAttributeRedactor` | Classify bounded fields through `TelemetryPolicy.classifyError`; exporter wrappers enforce the allowlist. |
| Arbitrary client log bodies and attributes | Use package-owned action, effect, dependency, and navigation signals. |
| `.production(endpoint:headers:)` bootstrap | Retain a `TelemetryRuntime` with TLS endpoints and a per-attempt `TelemetryRequestAuthenticator`. |
| Process-global bootstrap assumptions | Inject an isolated runtime or test client; package bootstrap does not replace OpenTelemetry globals. |
| Hardcoded production resource environment | Choose `.native(environment:)` to preserve package metadata with one bounded environment source, or `.strict(...)` for an exact registered key set whose environment is part of the resource payload. |
| Proposed arbitrary custom log/metric/span dictionaries | Register typed definitions in `TelemetryContractCatalog` and record only typed payloads. |
| `TelemetryClient.unsafeCustomSDK`, `MetricInstruments.unsafeCustomSDK`, public sanitizer/exporter/view hooks | Use normal typed package APIs. Direct OpenTelemetry integration is no longer exposed through regular products. |

Before migrating production composition, review [PRIVACY.md](PRIVACY.md), [SUPPORT.md](SUPPORT.md),
and the mobile runtime operational runbook. Production delivery remains bounded and best-effort; the
runtime does not guarantee export before suspension, termination, force-quit, crash, or device
shutdown.

## Adopting privacy-aware logs in 0.4.0-rc.2

The interpolated logging API is additive. Existing fixed package logs, registered log contracts, and
operational events remain source-compatible.

Replace ad hoc prose logging at application call sites with:

```swift
telemetry.log(
  .info,
  "Plan \(planID) save finished with \(TelemetryOutcome.success, privacy: .public)"
)
```

Unannotated values are private and render as `<private>`. A previous arbitrary string field must not
be mechanically changed to `privacy: .public`; strings, errors, URLs, custom descriptions, and
consumer-defined identifier kinds intentionally do not compile in that position. Choose a concrete
schema-bounded package identifier, finite enum, or explicit bounded log wrapper instead.

Callers that need synchronous acceptance information should handle
`TelemetryLogRecordingResult`. `.invalidMessage` indicates a reviewed template/body,
interpolation-count, or public-field bound was exceeded. `.recorded` does not guarantee remote
delivery.

## Adopting the remaining Phase 1 APIs in 0.4.0-rc.6

The rc.6 APIs are additive. Existing `.instrumented`, `.tracedRun`, `.tracedLongLivedRun`,
`traceStart`, `tracedCall`, navigation, typed contracts, counters, and rc.2 interpolated logs remain
source-compatible.

Register anonymous process-session context and log controls when constructing the policy:

```swift
let policy = TelemetryPolicy(
  schema: schema,
  catalog: catalog,
  signals: signals,
  hostContext: TelemetryHostContext(
    processSessionID: .current,
    platform: .current,
    processKind: .application
  ),
  logging: TelemetryLoggingConfiguration(
    minimumSeverity: .info,
    infoSampling: TelemetryLogSamplingRate(0.25)!,
    errorSampling: .always
  ),
  classifyError: classifyError
)
```

The process-session UUID is new for each process and is span/log-only. Do not replace it with an
account, device, installation, or persisted identifier. No metric query or dashboard migration is
needed because the context cannot become a metric dimension.

Tail promotion is opt-in. Build the existing runtime configuration, then set its additive property:

```swift
configuration.tailSampling = .enabled(
  try TelemetryTailSamplingPolicy(
    slowTraceThreshold: .seconds(2)
  )
)
```

Review the threshold and count/byte/age limits for the host. Unpromoted data is memory-only. Explicit
promotion must occur inside an active trace and returns `TelemetryTailPromotionResult`.

`TelemetryMetricExemplarPolicy` remains disabled by default. Opt in only after reviewing the finite
one-or-two per-data-point bound:

```swift
configuration.metricExemplars = .traceContext(maximumPerDataPoint: .one)
```

The exporter retains only valid SDK trace and span context and removes every exemplar attribute. This
does not add host context to metrics or change metric attributes, views, or series cardinality.
Exemplars do not promote traces or bypass tail retention; promoted root traces continue to export as
complete trees, including child spans that finish after promotion.

Use `.selectivelyInstrumented(feature:action:stateChangeToken:)` only when `nil` must mean no
telemetry. Keep `.instrumented(...)` when every action belongs to the finite schema. DEBUG-only
private console rendering requires the `debugConsole:` overload at each call site; no global switch
changes the default redacted behavior.
