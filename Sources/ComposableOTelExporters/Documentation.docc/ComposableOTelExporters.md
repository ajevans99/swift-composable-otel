# ``ComposableOTelExporters``

Bootstrap OpenTelemetry SDK providers with the exporters available in this release.

## Overview

``TelemetryBootstrap`` serializes process-global tracer, meter, and logger provider registration
on its first call and returns a `TelemetryClient` for TCA dependency injection. Repeated and
concurrent calls return the first cached client without re-registering providers. The first
configuration therefore owns process-wide bootstrap settings.

Instrumentation uses the providers cached in that returned client. The global registrations are a
compatibility boundary for upstream OpenTelemetry code, not a provider lookup path for normal
ComposableOTel spans, metrics, or logs. OpenTelemetry publishes the three provider globals through
separate upstream setters, so start compatibility global readers only after `configure` returns.

Both `.debug` and `.production` configure `StdoutSpanExporter`, `StdoutMetricExporter`, and
`StdoutLogExporter`. Production changes the default trace ratio from `1.0` to `0.1`, changes
metric export from every 5 seconds to every 60 seconds, and disables debug formatting. The
production endpoint and headers are reserved but unused.

This module does not currently provide remote OTLP transport, TLS or authentication handling,
retry or persistence, background lifecycle integration, or explicit flush and shutdown
ownership. ``ConsoleSpanExporter`` is available separately and is not installed by
``TelemetryBootstrap``.

## Topics

### Bootstrap

- ``TelemetryBootstrap``

### Exporters

- ``ConsoleSpanExporter``
