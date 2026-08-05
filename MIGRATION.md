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

## Adopting the remaining Phase 1 APIs in 0.4.0-rc.3

The rc.3 APIs are additive. Existing `.instrumented`, `.tracedRun`, `.tracedLongLivedRun`,
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

Use `.selectivelyInstrumented(feature:action:stateChangeToken:)` only when `nil` must mean no
telemetry. Keep `.instrumented(...)` when every action belongs to the finite schema. DEBUG-only
private console rendering requires the `debugConsole:` overload at each call site; no global switch
changes the default redacted behavior.
