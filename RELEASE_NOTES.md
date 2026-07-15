# swift-composable-otel 0.3.2

0.3.2 is a source-compatible pre-1.0 patch release that adds watchOS support and typed,
contract-bound operational events.

## watchOS 9 support

All three public library products now compile for watchOS 9 and CI builds each product for a generic
watchOS device. The typed contract, telemetry client, exporter/runtime, and testing APIs are
supported on watchOS.

The resolved `swift-composable-architecture` graph still fails a generic watchOS build because its
WatchKit lifecycle notification access is main-actor isolated. TCA-specific reducer and effect
conveniences are therefore conditionally unavailable on watchOS rather than forking or weakening
that dependency. They remain available on iOS and macOS.

## Typed operational events

`TelemetryOperationalEventDefinition<Payload>` registers bodyless, info-severity operational events
with exact typed finite fields. Synchronous, nonthrowing recording returns one bounded result:

- `.recorded` when the configured pipeline accepts the event;
- `.disabled` when operational events or the runtime are disabled;
- `.dropped` when the bounded queue rejects the event; or
- `.contractRejected` when registration or payload validation fails closed.

Operational events are enabled independently from package-owned logs, traces, and metrics. Names,
keys, scalar types, optionality, finite enum values, integer ranges, and conditional rules come only
from the registered definition and are validated again at the export privacy boundary. Existing
queue overflow, diagnostics, persistence, active-span correlation, consent disablement, and terminal
discard behavior remains authoritative. `.recorded` means synchronously accepted, not delivered over
the network.

`ComposableOTelTesting` adds exact ordered operational-event captures.

## Release history

Published GitHub Releases are now the canonical version history. The repository no longer maintains
a duplicate `CHANGELOG.md`; `RELEASE_NOTES.md` is the reviewed staging document for each release.

## Compatibility and migration

0.3.2 removes or changes no public symbols from 0.3.1. Existing iOS and macOS applications require no
migration. watchOS applications can use the contract/client/runtime/testing surfaces but do not
receive the TCA-specific reducer and effect conveniences described above.

Local loopback OTLP development remains available through the explicit, development/test-only
endpoint policy introduced in
[0.3.1](https://github.com/ajevans99/swift-composable-otel/releases/tag/0.3.1). HTTPS remains the
default, and staging, production, LAN, non-loopback, and mixed local/remote endpoint configurations
remain rejected.

The broader 0.2.2-to-0.3.x migration remains documented in [MIGRATION.md](MIGRATION.md).

## Accepted residual risks

This source-compatible patch does not satisfy the remaining 1.0 go/no-go items.

| Risk | Scope and mitigation | Owner | Reviewer | Reconsideration |
| --- | --- | --- | --- | --- |
| Missing external production-like evidence | No external consumer has supplied the physical-device, gateway, privacy, delivery, and resource-usage evidence defined in [PILOT.md](PILOT.md). Package-owned CI and bounded defaults reduce risk; adopters must complete that evidence contract for their own production use. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Unprotected default branch | Repository administration does not enforce default-branch protection or required checks. The maintainer must verify the complete hosted release CI on the exact release commit before tagging; protection remains mandatory for 1.0. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Exact empty `severity_text` unsupported | The upstream OpenTelemetry Swift model and encoder cannot represent an explicitly empty severity-text field through supported APIs. 0.3.2 guarantees the documented EventName, severity, body, typed-field, and contract-version behavior and does not add a raw encoding bypass. | `ajevans99` | `ajevans99` | 2026-10-13 |

The complete 1.0 go/no-go decision remains defined in [RELEASING.md](RELEASING.md).
