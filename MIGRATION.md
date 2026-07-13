# Unreleased Migration Guide

The changes below describe migration from the current `0.2.2` tag to the unreleased package state.
No 1.0 release has been tagged or published.

| Previous API or behavior | Unreleased replacement |
| --- | --- |
| Reflection-derived reducer and action names | Pass typed `feature:` and `action:` values to `.instrumented(...)`. |
| State description comparison | Supply an optional opaque `StateChangeToken`; omit it when no non-sensitive token exists. |
| String effect and dependency names | Use `EffectID`, `DependencyID`, and `OperationID` values present in `TelemetrySchema`. |
| `.traced()` marker | Use `.traceStart(effect:)`; use `.tracedRun` or `.tracedLongLivedRun` for lifecycle outcomes. |
| `configureTestTelemetry` | Use `TelemetryClient.test(metricReader:policy:)` and inject the returned client. |
| `ErrorDetailPolicy` and `SpanAttributeRedactor` | Classify bounded fields through `TelemetryPolicy.classifyError`; exporter wrappers enforce the allowlist. |
| Arbitrary client log bodies and attributes | Use package-owned action, effect, dependency, and navigation signals. |
| `.production(endpoint:headers:)` bootstrap | Retain a `TelemetryRuntime` with TLS endpoints and a per-attempt `TelemetryRequestAuthenticator`. |
| Process-global bootstrap assumptions | Inject an isolated runtime or test client; package bootstrap does not replace OpenTelemetry globals. |
| Hardcoded production resource environment | Use `TelemetryDeploymentEnvironment`; the source-compatible runtime default remains `.production`. |
| Proposed arbitrary custom log/metric/span dictionaries | Register typed definitions in `TelemetryContractCatalog` and record only typed payloads. |

Before migrating production composition, review [PRIVACY.md](PRIVACY.md), [SUPPORT.md](SUPPORT.md),
and the mobile runtime operational runbook. Production delivery remains bounded and best-effort; the
runtime does not guarantee export before suspension, termination, force-quit, crash, or device
shutdown.
