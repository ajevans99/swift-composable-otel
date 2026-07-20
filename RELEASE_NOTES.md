# swift-composable-otel 0.3.3

0.3.3 is a source-compatible pre-1.0 patch release that adds a privacy-ordered observer exporter
extension point for on-device debug tooling.

## Sanitized observer exporters

`TelemetryObserverExporters` accepts independent arrays of standard OpenTelemetry Swift
`SpanExporter`, `LogRecordExporter`, and `MetricExporter` values:

```swift
let inspector = InspectorTelemetry()
let exporterSet = inspector.makeExporters()
let observers = TelemetryObserverExporters(
  spanExporters: [exporterSet.spanExporter],
  logRecordExporters: [exporterSet.logExporter],
  metricExporters: [exporterSet.metricExporter]
)
```

Pass `observerExporters: observers` to `TelemetryBootstrap.configure` for development stdout or to
`TelemetryRuntime.Configuration` for the bounded OTLP runtime. The original overloads remain
unchanged and construct an empty observer set, so existing call sites and production behavior remain
unchanged. Retain `inspector` for its stores and UI. Scope `exporterSet` to exactly one bootstrap or
runtime lifetime; call `inspector.makeExporters()` again for a separate configuration.

Package-owned processors and readers keep every observer behind the same `TelemetryPolicy` privacy
boundary as stdout and OTLP. Observers see only enabled, sampled, sanitized spans, logs, resources,
and metrics. Native metrics and registered delta counters use separate internal readers but preserve
one lifecycle for each supplied metric exporter.

Observer failure results are isolated from normal stdout and OTLP export. Runtime force flush and
graceful shutdown flush observers; graceful shutdown and terminal discard shut them down exactly
once. Terminal discard does not collect pending observer metrics. Data already accepted by any
exporter is a completed export and cannot be retracted. Each supplied exporter transfers lifecycle
ownership to one bootstrap or runtime; separate configurations must use fresh exporter instances,
though those exporters may share independently retained stores.

## Compatibility and migration

0.3.3 removes or changes no public symbols from 0.3.2. Existing applications require no migration.
On-device inspectors should be composed under `#if DEBUG` when they must not ship in production.

The broader 0.2.2-to-0.3.x migration remains documented in [MIGRATION.md](MIGRATION.md).

## Accepted residual risks

This source-compatible patch does not satisfy the remaining 1.0 go/no-go items.

| Risk | Scope and mitigation | Owner | Reviewer | Reconsideration |
| --- | --- | --- | --- | --- |
| Missing external production-like evidence | No external consumer has supplied the physical-device, gateway, privacy, delivery, and resource-usage evidence defined in [PILOT.md](PILOT.md). Package-owned CI and bounded defaults reduce risk; adopters must complete that evidence contract for their own production use. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Unprotected default branch | Repository administration does not enforce default-branch protection or required checks. The maintainer must verify the complete hosted release CI on the exact release commit before tagging; protection remains mandatory for 1.0. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Exact empty `severity_text` unsupported | The upstream OpenTelemetry Swift model and encoder cannot represent an explicitly empty severity-text field through supported APIs. 0.3.3 guarantees the documented EventName, severity, body, typed-field, and contract-version behavior and does not add a raw encoding bypass. | `ajevans99` | `ajevans99` | 2026-10-13 |

The complete 1.0 go/no-go decision remains defined in [RELEASING.md](RELEASING.md).
