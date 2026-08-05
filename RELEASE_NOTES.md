# swift-composable-otel 0.4.0-rc.1

0.4.0-rc.1 is a source-compatible pre-1.0 prerelease that adds privacy-aware interpolated
application logs. It is intended for Momentum integration testing before the final 0.4.0 release.

## Privacy-aware interpolated logs

`TelemetryClient` now accepts OSLog-style prose through `TelemetryLogMessage`:

```swift
telemetry.log(
  .info,
  "Plan \(planID) save finished with \(TelemetryOutcome.success, privacy: .public)"
)
```

Every unannotated interpolation is private. It is never evaluated or retained and becomes the fixed
`<private>` token before any OpenTelemetry exporter, observer exporter, persistence queue, test
collector that models remote output, or other retained telemetry path.

Explicit `.public` interpolation is available only for package-approved bounded values: concrete
package identifier domains, `TelemetryOutcome`, `NavigationOperation`, `Bool`,
`TelemetryLogInteger`, `TelemetryLogDuration`, `TelemetryLogCountBucket`, and
`TelemetryCorrelationID`. Bare strings, errors, URLs, arbitrary descriptions, and externally
defined identifier kinds cannot be made public.

Each accepted record exports the stable `app.log` event name, canonical template, deterministic
template identity, sanitized body, severity, typed public fields, and active trace/span context.
Templates are limited to 512 UTF-8 bytes, rendered bodies to 1,024 UTF-8 bytes, interpolations to
16, and public values to 8. `TelemetryLogRecordingResult` reports synchronous acceptance,
disablement, dropping, or invalid-message rejection.

`ComposableOTelTesting` exposes decoded privacy-aware captures for exact assertions over template,
template identity, redacted body, severity, typed public values, and trace correlation.

## Compatibility and migration

The release removes or changes no public symbols from 0.3.3. Existing fixed package logs, typed
contract logs, operational events, and runtime composition remain source-compatible.

Because this is a prerelease, consumers should pin it exactly:

```swift
.package(
  url: "https://github.com/ajevans99/swift-composable-otel.git",
  exact: "0.4.0-rc.1"
)
```

Do not mechanically mark an existing arbitrary string field `.public`; instead choose a concrete
schema-bounded identifier, finite enum, or bounded wrapper. See [MIGRATION.md](MIGRATION.md) and
[Privacy-aware logs](Sources/ComposableOTel/Documentation.docc/Articles/PrivacyAwareLogs.md).

## Accepted residual risks

This prerelease does not satisfy the remaining 1.0 go/no-go items.

| Risk | Scope and mitigation | Owner | Reviewer | Reconsideration |
| --- | --- | --- | --- | --- |
| Missing external production-like evidence | No external consumer has supplied the physical-device, gateway, privacy, delivery, and resource-usage evidence defined in [PILOT.md](PILOT.md). Package-owned CI and bounded defaults reduce risk; adopters must complete that evidence contract for their own production use. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Unprotected default branch | Repository administration does not enforce default-branch protection or required checks. The maintainer must verify the complete hosted release CI on the exact release commit before tagging; protection remains mandatory for 1.0. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Local private rendering deferred | A development-only mode was not added because private values must not enter observers, persistence, tail buffers, OTLP, or remote-modeling test stores. Private interpolation remains redacted in every retained path. | `ajevans99` | `ajevans99` | Before 0.4.0 |
| Exact empty `severity_text` unsupported | The upstream OpenTelemetry Swift model and encoder cannot represent an explicitly empty severity-text field through supported APIs. This release guarantees the documented event name, severity, body, typed-field, and contract-version behavior without a raw encoding bypass. | `ajevans99` | `ajevans99` | 2026-10-13 |

The complete 1.0 go/no-go decision remains defined in [RELEASING.md](RELEASING.md).
