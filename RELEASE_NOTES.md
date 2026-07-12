# Unreleased Package Release Notes

This package-side release candidate adds the evidence needed to evaluate a future stable release. It
does not announce, tag, or publish 1.0.

## Quality and runtime evidence

- Expanded reducer, effect, dependency, privacy, error, cardinality, cancellation, long-lived,
  persistence, retry, timeout, overflow, lifecycle, and concurrency assertions.
- Target-specific coverage floors, including a dedicated production runtime floor.
- Thread Sanitizer, current iOS simulator, generic iOS product, minimum/latest dependency endpoint,
  DocC, public API compatibility, and semantic-convention review gates.
- Reproducible release benchmarks and checked performance, memory, and queue budgets.
- A commit-pinned `swift-format` selection instead of the mutable runner-installed formatter.

## Operations and migration

Production composition uses the lifecycle-owning `TelemetryRuntime`; migration details are in
[MIGRATION.md](MIGRATION.md). Security and privacy responsibilities are in
[SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md). Performance limits are in
[PERFORMANCE.md](PERFORMANCE.md), and the exporter DocC catalog contains the operational runbook.

## Known constraints

- Delivery is best-effort under Apple lifecycle suspension and termination.
- iOS 17 is the deployment floor, but hosted tests run on the current available simulator.
- watchOS remains unsupported because the declared graph does not pass the named support gate.
- The consumer pilot and repository branch-protection evidence remain external release blockers.

The complete future 1.0 go/no-go decision is defined in [RELEASING.md](RELEASING.md).
