# swift-composable-otel 0.4.0-rc.6

0.4.0-rc.6 supersedes 0.4.0-rc.4 and 0.4.0-rc.5.
rc.4 was published with stale embedded rc.3 metadata and documentation.
Do not adopt rc.4: its embedded package and instrumentation version and its installation and release
documentation still identify rc.3. Do not adopt rc.5: adding registered host context could leave
sanitized span total counts below retained counts and trap the upstream OTLP encoder during
`forceFlush`. Both tags and releases remain immutable and must not be moved or reused.

rc.6 preserves each source span's SDK-recorded attribute, event, and link drops while rebuilding its
totals from the sanitized retained values. Malformed totals normalize without subtraction underflow,
and unrepresentable totals fail closed. Production runtime tests force-flush registered and package
signals through real OTLP protobuf request encoding and verify host context remains limited to spans
and logs. This candidate changes or removes no public APIs. It remains a pre-1.0 candidate for Momentum
integration and production-like validation; it is not the 0.4.0 final release.

## Default-off bounded metric trace exemplars

PR #26 adds `TelemetryMetricExemplarPolicy`. Existing bootstrap and runtime behavior remains
`.disabled` and removes every exemplar. Opting into `.traceContext(maximumPerDataPoint: .one)` or
`.two` retains at most one or two exemplars per metric data point, respectively. Only exemplars with
valid SDK trace and span context are retained. The export boundary retains zero exemplar attributes.
The policy adds no host context to metrics and changes no metric attributes or views.
Metric series cardinality does not increase.

Exemplar links do not promote a trace or allow a partial trace to bypass tail retention. Tail
promotion continues to export the complete promoted root trace, including child spans that finish
after promotion, through the existing bounded delivery path.

## Cross-signal process-session context

`TelemetryHostContext` registers one anonymous process-session UUID plus finite platform and process
kind values. The privacy boundary injects the validated context into sanitized spans and logs,
including reducer, effect, and dependency async work. Native metrics and registered counters exclude
all host-context keys by construction.

## Bounded tail promotion

`TelemetryTailSamplingConfiguration` and `TelemetryTailSamplingPolicy` add opt-in client-side recovery
for traces missed by ordinary head sampling. Sanitized spans and correlated breadcrumbs remain
memory-only until an error, reviewed slow threshold, or explicit
`TelemetryClient.triggerDiagnosticTracePromotion()` promotes the current root trace.

Retention has independent trace, span, breadcrumb, byte-estimate, and age ceilings. Head sampling
remains additive. Promoted signals use the existing bounded queues, privacy exporters, official OTLP
encoding, optional persistence, observer lifecycle, and terminal discard behavior. If a discarded
trace cannot accompany an error log, the runtime removes trace/span correlation before exporting the
error.

## Logging controls and DEBUG rendering

`TelemetryLoggingConfiguration` applies severity filtering and deterministic per-severity sampling
using stable log identity rather than dynamic or private values. Logs remain disabled by default and
errors can remain fully retained.

DEBUG builds add the explicitly selected `TelemetryDebugConsoleRenderer`. Its overload evaluates
private interpolation only for one immediate local render. The normal retained record remains
redacted, and the private body bypasses collectors, observers, tail buffers, queues, persistence,
OTLP, and every remote path. Release builds contain no renderer symbol.

## Selective reducer instrumentation and testing

`.selectivelyInstrumented(feature:action:stateChangeToken:)` accepts an `ActionID?`. A `nil` action
emits no reducer, effect, dependency, log, or metric telemetry instead of aggregating to `other`.
Existing reducer/effect/dependency/navigation and typed-span APIs remain unchanged.

`ComposableOTelTesting` adds decoded span trees, typed span/log metadata, host-context captures,
trace/span correlation, tail-retention state, and metric context-exclusion assertions.

No general histogram API was added. Momentum's reviewed low-cardinality flow latency remains modeled
by typed bounded spans and their captured/exported duration, avoiding an uncontrolled TCA metric
dimension cross-product.

## Compatibility and migration

The release removes or changes no public symbols from 0.4.0-rc.5. Consumers must pin the prerelease
exactly:

```swift
.package(
  url: "https://github.com/ajevans99/swift-composable-otel.git",
  exact: "0.4.0-rc.6"
)
```

See [MIGRATION.md](MIGRATION.md), [PRIVACY.md](PRIVACY.md), and the package DocC guides before
enabling host context, tail promotion, bounded metric exemplars, or DEBUG private rendering.

## Accepted residual risks

| Risk | Scope and mitigation | Owner | Reviewer | Reconsideration |
| --- | --- | --- | --- | --- |
| Missing external production-like evidence | Package CI covers privacy, limits, concurrency, lifecycle, compatibility, platforms, and performance, but the physical-device and gateway evidence in [PILOT.md](PILOT.md) remains consumer-owned. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Unprotected default branch | Repository administration does not enforce default-branch protection or required checks. Verify complete hosted CI on the exact merge commit before creating an rc.6 tag. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Best-effort mobile completion | Suspension, termination, force-quit, crash, and device shutdown can interrupt memory-only tail retention and queued export. Bounded persistence applies only after promotion and queue encoding. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Exact empty `severity_text` unsupported | The upstream OpenTelemetry Swift model cannot represent an explicitly empty severity-text through supported APIs. No raw OTLP bypass was added. | `ajevans99` | `ajevans99` | 2026-10-13 |

Recommend creating the immutable `0.4.0-rc.6` tag only after this release pull request is merged and
every hosted release gate passes on its merge commit. Momentum must then pin rc.6 and prove its
production vertical slice and CI against that immutable tag in its existing adoption pull request.
Only after that evidence is accepted should the byte-identical `0.4.0` final be requested from the
exact same upstream commit and that same Momentum pull request updated; do not make a separate
final-code or release-metadata change. The final alias therefore intentionally retains the candidate's
`0.4.0-rc.6` embedded telemetry version so the validated bits remain identical.
