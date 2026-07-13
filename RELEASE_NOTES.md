# swift-composable-otel 0.3.0

0.3.0 is a pre-1.0 minor release that replaces the 0.2.2 prototype with bounded, privacy-preserving
instrumentation and a lifecycle-owning OTLP/HTTP runtime. It does not claim 1.0 readiness.

## Highlights

- Task-local-safe reducer, effect, and dependency tracing with explicit parenting and balanced
  success, cancellation, error, and long-lived outcomes.
- Typed finite identifiers, allowlist-first privacy filtering, bounded cardinality, independent
  signal controls, and logs disabled by default.
- A production `TelemetryRuntime` with TLS endpoint validation, per-attempt authentication, bounded
  batching, retry/backoff, timeouts, optional atomic persistence, lifecycle hooks, diagnostics, and
  terminal consent-revocation discard.
- Typed external contract catalogs for custom spans, bodyless EventName logs, delta counters, exact
  resources, conditional fields, and bounded metric points.
- Supported iOS 17 and macOS 14 package surfaces with minimum/latest dependency lanes, current iOS
  simulator coverage, TSan, coverage floors, API and semantic locks, benchmarks, and DocC gates.
- Split-encoding failure isolation is tested from the dispatcher's production-style dedicated queue,
  and macOS CI test steps have a bounded 10-minute timeout.

## Migration and operations

This release contains documented pre-1.0 API and behavior changes. Follow [MIGRATION.md](MIGRATION.md)
when upgrading from 0.2.2. Production composition uses a retained `TelemetryRuntime`; security,
privacy, performance, and operational responsibilities are documented in [SECURITY.md](SECURITY.md),
[PRIVACY.md](PRIVACY.md), [PERFORMANCE.md](PERFORMANCE.md), and the exporter DocC runbook.

Delivery remains best-effort when Apple platforms suspend or terminate an application. Consent
revocation requires replacing the host client with `.noop` and calling
`disableAndDiscardPending()`; pausing export or orderly shutdown is not opt-out.

## Accepted residual risks

The maintainer accepts the following risks for this pre-1.0 release. Each remains a no-go item for
1.0 and must be reconsidered by 2026-10-13.

| Risk | Scope and mitigation | Owner | Reviewer | Reconsideration |
| --- | --- | --- | --- | --- |
| Missing external production-like evidence | No external consumer has supplied the physical-device, gateway, privacy, delivery, and resource-usage evidence defined in [PILOT.md](PILOT.md). Package-owned CI and bounded defaults reduce risk; adopters must complete that evidence contract for their own production use. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Unprotected default branch | Repository administration does not enforce default-branch protection or required checks. The maintainer must verify the complete hosted release CI on the exact release commit before tagging; protection remains mandatory for 1.0. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Exact empty `severity_text` unsupported | The upstream OpenTelemetry Swift model and encoder cannot represent an explicitly empty severity-text field through supported APIs. 0.3.0 guarantees the documented EventName, severity, body, typed-field, and contract-version behavior and does not add a raw encoding bypass. | `ajevans99` | `ajevans99` | 2026-10-13 |
| watchOS unsupported | The manifest supports iOS and macOS only because the inherited graph has not passed the named watchOS gate. The package makes no watchOS claim until all products compile, maintained CI exercises the relevant surface, and lifecycle limits are documented. | `ajevans99` | `ajevans99` | 2026-10-13 |

The complete 1.0 go/no-go decision remains defined in [RELEASING.md](RELEASING.md).
