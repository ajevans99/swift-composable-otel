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

Action and navigation logs are disabled by default. Signal controls are independent, and trace
sampling does not disable metrics or logs.

## Host responsibilities

The host remains responsible for classification, notice or consent, schema review, endpoint and
gateway access, retention, deletion, regional routing, and incident response. A value being accepted
by the identifier grammar does not make it non-sensitive; only pre-reviewed schema constants belong
in production.

`TelemetryClient.unsafeCustomSDK` and `MetricInstruments.unsafeCustomSDK` are explicit trust
boundaries. Custom SDK processors, readers, or exporters can bypass package enforcement unless the
host installs equivalent privacy wrappers, metric views, and resource filtering.

## Release and pilot evidence

Every release candidate must pass sentinel-secret leakage and state/action non-capture tests. A
production pilot must supply the privacy-review evidence defined in [PILOT.md](PILOT.md); this
repository does not infer approval from successful delivery.
