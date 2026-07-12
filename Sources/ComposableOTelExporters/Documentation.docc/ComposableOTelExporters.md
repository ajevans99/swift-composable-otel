# ``ComposableOTelExporters``

Configure the package-owned privacy boundary and stdout exporters.

## Overview

``TelemetryBootstrap`` creates bounded tracer, meter, and logger providers once and returns the
injected `TelemetryClient`. It does not replace process-global OpenTelemetry providers. Traces,
logs, metrics, and resources are filtered before the underlying stdout exporters receive them.

``PrivacyPreservingSpanExporter`` sanitizes names, attributes, events, links, status, and resources.
``PrivacyPreservingLogRecordExporter`` rebuilds records from allowlisted bodies, attributes, event
names, and resources. ``PrivacyPreservingMetricExporter`` drops unknown instruments and unsafe
resources, sanitizes dimensions, and removes exemplars.

``ComposableOTelMetricConfiguration`` installs a catch-all drop view plus per-instrument views with
dimension processors and duration histograms. It also creates instruments with stable descriptions
and units.

Both bootstrap environments remain stdout-only. Production endpoint and headers are unused. This
module does not provide OTLP transport, TLS/authentication, retry, persistence, lifecycle ownership,
or remote delivery.

Custom SDK integrations must install all three wrappers, package metric views, and a resource
sanitized by the same policy. Otherwise they are outside the package trust boundary.

## Topics

### Bootstrap

- ``TelemetryBootstrap``

### Policy boundary

- ``PrivacyPreservingSpanExporter``
- ``PrivacyPreservingLogRecordExporter``
- ``PrivacyPreservingMetricExporter``
- ``ComposableOTelMetricConfiguration``

### Console

- ``ConsoleSpanExporter``
