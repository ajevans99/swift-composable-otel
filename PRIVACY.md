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
- replaces unannotated log interpolations with a fixed token during message construction;
- permits public log interpolation only for package-approved finite or explicitly bounded values;
- preserves a bounded canonical log template and identity separately from rendered values;
- applies severity filtering and deterministic sampling without hashing private values;
- evaluates private interpolation only for an explicitly requested DEBUG-only immediate renderer;
- attaches an anonymous process-session context only to sanitized spans and logs;
- excludes process-session context from native and registered metric dimensions;
- retains only sanitized, bounded, memory-only tail entries before promotion;
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

Action and navigation logs and contract-bound operational events are disabled by default. Their
controls are independent, so enabling registered operational events does not enable package-owned
logs. Trace sampling does not disable metrics, logs, or operational events.

Privacy-aware interpolated logs use the `logsEnabled` control. Their `app.log` records are rebuilt
from a canonical template and typed public fields at the privacy boundary. Private values are already
gone before the OpenTelemetry logger is called. Production runtime observers, bounded queues, OTLP encoding, persistence, and tail retention receive
only that rebuilt record. The DEBUG-only `debugConsole:` overload evaluates private autoclosures for
one immediate renderer invocation. It does not send the private body through any SDK, observer,
collector, queue, tail buffer, persistence, or remote path, and it is absent from release builds.

Registered `TelemetryHostContext` contains only an anonymous process-lifetime UUID and finite platform
and process-kind enums. The privacy boundary removes forged context fields and injects the registered
value into sanitized spans and logs. Metric sanitizers remove these keys, registered contracts reserve
them, and metric instruments never receive them.

Optional tail promotion changes recording, not the privacy boundary. Head-missed spans and correlated
breadcrumbs are sanitized before entering a buffer bounded by count, encoded-byte estimate, and age.
Unpromoted entries are memory-only and discarded. Promoted entries enter the ordinary bounded queues;
only then can they be encoded or persisted. An error log whose trace was deliberately discarded is
exported only after its trace/span correlation is removed.

## Host responsibilities

The host remains responsible for classification, notice or consent, schema review, endpoint and
gateway access, retention, deletion, regional routing, and incident response. A value being accepted
by the identifier grammar does not make it non-sensitive; only pre-reviewed schema constants belong
in production.

Raw SDK client/instrument factories, dictionary sanitizers, privacy processors, readers, and
metric-view builders are not public in normal products. `TelemetryObserverExporters` accepts only
standard exporters, and package-owned processors/readers ensure they receive values after the same
privacy boundary. A host that integrates OpenTelemetry directly is outside this package's
enforcement.

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

Terminal discard shuts observer exporters down without collecting pending metrics. It cannot retract
data that an observer already accepted, just as it cannot retract a completed network export or
stdout write. Hosts using an on-device store remain responsible for that store's deletion and
retention policy.

## Release and pilot evidence

Every release candidate must pass sentinel-secret leakage, DEBUG renderer isolation, tail-buffer
limits, metric context exclusion, and state/action non-capture tests. A
production pilot must supply the privacy-review evidence defined in [PILOT.md](PILOT.md); this
repository does not infer approval from successful delivery.
