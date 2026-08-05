# swift-composable-otel 0.4.0-rc.3

0.4.0-rc.3 supersedes 0.4.0-rc.2 and completes the planned Phase 1 prerelease surface without changing
or removing existing public APIs. It remains a pre-1.0 candidate for Momentum integration and
production-like validation; it is not the 0.4.0 final release.

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

The release removes or changes no public symbols from 0.4.0-rc.2. Consumers must pin the prerelease
exactly:

```swift
.package(
  url: "https://github.com/ajevans99/swift-composable-otel.git",
  exact: "0.4.0-rc.3"
)
```

See [MIGRATION.md](MIGRATION.md), [PRIVACY.md](PRIVACY.md), and the package DocC guides before
enabling host context, tail promotion, or DEBUG private rendering.

## Accepted residual risks

| Risk | Scope and mitigation | Owner | Reviewer | Reconsideration |
| --- | --- | --- | --- | --- |
| Missing external production-like evidence | Package CI covers privacy, limits, concurrency, lifecycle, compatibility, platforms, and performance, but the physical-device and gateway evidence in [PILOT.md](PILOT.md) remains consumer-owned. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Unprotected default branch | Repository administration does not enforce default-branch protection or required checks. Verify complete hosted CI on the exact merge commit before creating an rc.3 tag. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Best-effort mobile completion | Suspension, termination, force-quit, crash, and device shutdown can interrupt memory-only tail retention and queued export. Bounded persistence applies only after promotion and queue encoding. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Exact empty `severity_text` unsupported | The upstream OpenTelemetry Swift model cannot represent an explicitly empty severity-text through supported APIs. No raw OTLP bypass was added. | `ajevans99` | `ajevans99` | 2026-10-13 |

Recommend creating the immutable `0.4.0-rc.3` tag only after this pull request is merged and every
hosted release gate passes on the merge commit. Do not tag 0.4.0 final from this change.
