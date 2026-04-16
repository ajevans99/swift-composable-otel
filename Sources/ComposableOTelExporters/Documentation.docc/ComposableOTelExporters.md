# ``ComposableOTelExporters``

SDK bootstrap and exporters for ComposableOTel.

## Overview

This module provides the ``TelemetryBootstrap`` entry point that
configures OpenTelemetry SDK providers (tracer, meter, logger) with
sensible defaults. It also includes a ``ConsoleSpanExporter`` for
human-readable span output during development.

Import this module in your application target. Test and library targets
typically only need `ComposableOTel` and `ComposableOTelTesting`.

## Topics

### Bootstrap

- ``TelemetryBootstrap``

### Exporters

- ``ConsoleSpanExporter``
