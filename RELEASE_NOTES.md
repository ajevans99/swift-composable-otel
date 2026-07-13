# Unreleased Package Release Notes

This package-side release candidate adds the evidence needed to evaluate a future stable release. It
does not announce, tag, or publish 1.0.

Because the catalog/resource additions are pre-1.0 public API, the eventual candidate should be a
minor release such as `0.3.0` after all external gates pass. This repository change does not create
that tag or release.

## Dependency baseline

These gates are layered on `main` with terminal-discard commit
`038f26e69ff876c531172679e4463a5df1977921`. They must not be presented as consent-revocation
acceptance against the earlier runtime head `7814d29`.

## Quality and runtime evidence

- Expanded reducer, effect, dependency, privacy, error, cardinality, cancellation, long-lived,
  persistence, retry, timeout, overflow, lifecycle, and concurrency assertions.
- Target-specific coverage floors, including a dedicated production runtime floor.
- Thread Sanitizer, current iOS simulator, generic iOS product, minimum/latest dependency endpoint,
  DocC, public API compatibility, and semantic-convention review gates.
- Reproducible release benchmarks and checked performance, memory, and queue budgets.
- A commit-pinned `swift-format` selection instead of the mutable runner-installed formatter.
- A 64 KiB default encoded-body ceiling, conservative 25-item gateway batch evidence, bounded
  numeric `Retry-After`, and explicit 401/413 terminal handling.
- Typed bootstrap-registered custom spans, bodyless EventName logs, delta counters, exact resources,
  conditional-field enforcement, and decoded/no-network testing captures.

## Operations and migration

Production composition uses the lifecycle-owning `TelemetryRuntime`; migration details are in
[MIGRATION.md](MIGRATION.md). Security and privacy responsibilities are in
[SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md). Performance limits are in
[PERFORMANCE.md](PERFORMANCE.md), and the exporter DocC catalog contains the operational runbook.
Consent revocation requires swapping the host client to `.noop` and calling
`disableAndDiscardPending()`; export unavailability and graceful shutdown are explicitly not
accepted as opt-out.

## Known constraints

- Delivery is best-effort under Apple lifecycle suspension and termination.
- iOS 17 is the deployment floor, but hosted tests run on the current available simulator.
- watchOS remains unsupported because the declared graph does not pass the named support gate.
- The consumer pilot and repository branch-protection evidence remain external release blockers.

The complete future 1.0 go/no-go decision is defined in [RELEASING.md](RELEASING.md).
