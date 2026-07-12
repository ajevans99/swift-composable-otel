# ``ComposableOTelExporters``

Bootstrap OpenTelemetry SDK providers with the exporters available in this release.

## Overview

``TelemetryBootstrap`` registers process-global tracer, meter, and logger providers and returns a
`TelemetryClient` for TCA dependency injection.

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
