# ``ComposableOTelExporters``

Configure the package-owned privacy boundary, development stdout, and production mobile OTLP.

## Overview

``TelemetryRuntime`` owns isolated tracer, meter, and logger providers; bounded processors and
readers; official OTLP/HTTP encoders; request delivery; optional persistence; and lifecycle state.
It validates TLS endpoints, applies host-supplied short-lived authentication on every attempt, and
exposes only its feature-facing `TelemetryClient`.

``TelemetryBootstrap`` remains an explicit development-only stdout path. Neither path replaces
process-global OpenTelemetry providers.

Package-only processors rebuild spans, logs, metrics, and resources from native or catalog
allowlists before encoding. Metric views are drop-by-default with exact dimensions, descriptions,
units, temporality, and histograms. These implementation hooks are intentionally absent from the
normal public API.

Read <doc:MobileOTLPRuntime>, <doc:OperationalRunbook>, and <doc:ProductionReadiness> before enabling
remote export. Mobile delivery remains best-effort: suspension and termination can interrupt every
queue, retry, persistence, or flush strategy.

Custom SDK integrations must install all three wrappers, package metric views, and a resource
sanitized by the same policy. Otherwise they are outside the package trust boundary.

## Topics

### Bootstrap

- ``TelemetryBootstrap``
- ``TelemetryRuntime``
- ``OTLPEndpoints``
- ``TelemetryHTTPTransport``
- ``TelemetryRequestAuthenticator``
- ``TelemetryBatchConfiguration``
- ``TelemetryDeliveryConfiguration``
- ``TelemetryPersistenceConfiguration``

### Lifecycle and diagnostics

- ``TelemetryRuntimeOperationResult``
- ``TelemetryRuntimeDiagnostics``
- ``TelemetryRuntimeDiagnosticEvent``
- ``TelemetryExportCondition``

### Articles

- <doc:MobileOTLPRuntime>
- <doc:OperationalRunbook>
- <doc:ProductionReadiness>

### Console

- ``ConsoleSpanExporter``
