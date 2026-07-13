# Privacy Guidance

`swift-composable-otel` does not phone home, create a network runtime, or collect application data by
itself. A host explicitly creates `TelemetryRuntime`, supplies endpoints and authentication, chooses
a bounded schema, and decides when signals are enabled.

## Enforced package boundary

Package-owned instrumentation:

- uses typed identifiers and finite schema allowlists;
- aggregates valid but unconfigured values to `other`;
- emits fixed span, event, metric, and log names;
- never reflects or describes reducer actions or state;
- compares optional state-change tokens only in memory;
- exports bounded error classification rather than descriptions, payloads, URLs, or stack traces;
- sanitizes resources, spans, logs, metrics, events, links, and exemplars before package queues;
- persists only sanitized OTLP bodies and a small content-header allowlist; and
- never persists authorization, cookies, or arbitrary request headers.

Registered external contracts remain allowlist-first. Names, field keys, scalar types, values,
conditional combinations, body policy, severity, unit, contract version, and counter series are
fixed at bootstrap. Recording takes typed payloads only. Exporters rebuild registered signals and
drop raw SDK attempts with extra keys, wrong types, invalid combinations, or an incorrect version.

Native resource mode preserves the package's established SDK/distribution metadata. Strict resource
mode is opt-in and emits only one registered exact required key set plus integer contract version;
it never silently mixes native metadata into the strict contract.

Action and navigation logs are disabled by default. Signal controls are independent, and trace
sampling does not disable metrics or logs.

## Host responsibilities

The host remains responsible for classification, notice or consent, schema review, endpoint and
gateway access, retention, deletion, regional routing, and incident response. A value being accepted
by the identifier grammar does not make it non-sensitive; only pre-reviewed schema constants belong
in production.

Raw SDK client/instrument factories, dictionary sanitizers, privacy processors, and metric-view
builders are not public in normal products. They use Swift `package` access for exporter/testing
wiring. A host that integrates OpenTelemetry directly is outside this package's enforcement.

## Consent revocation and opt-out

`setExportCondition(.unavailable)` is only a scheduling pause. The runtime continues to accept,
sanitize, queue, and optionally persist telemetry while export is unavailable.
`shutdown()` is an orderly lifecycle operation: it attempts a flush and retains timed-out persisted
records for relaunch. Neither operation implements consent revocation.

For opt-out or a privacy kill switch, the host must first replace its facade/dependency client with
`TelemetryClient.noop`, then call `disableAndDiscardPending()`. The terminal operation skips flush,
cancels delivery/retry work, rejects later signals, deletes in-memory and persisted telemetry, shuts
down providers, and cannot be reversed by lifecycle or export-condition updates. Deletion failures
remain visible in the operation result and diagnostics and must be retried/reviewed.

## Release and pilot evidence

Every release candidate must pass sentinel-secret leakage and state/action non-capture tests. A
production pilot must supply the privacy-review evidence defined in [PILOT.md](PILOT.md); this
repository does not infer approval from successful delivery.
