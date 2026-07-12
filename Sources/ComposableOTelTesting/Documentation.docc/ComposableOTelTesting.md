# ``ComposableOTelTesting``

In-memory helpers for inspecting ComposableOTel instrumentation.

## Overview

Use ``ComposableOTel/TelemetryClient/test(metricReader:errorDetailPolicy:)`` to create a client
and ``TestCollectors``. Inject the client through TCA dependencies, exercise the feature, call
``TestCollectors/forceFlush()``, and inspect spans or logs.

The factory owns its providers locally and does not replace `OpenTelemetry.instance` globals.
Independently injected clients therefore retain isolated span, metric, and log pipelines. The
deprecated `configureTestTelemetry` helper is the global-provider compatibility path and must be
serialized.

The optional in-memory metric reader is provisional in `0.2.2`, but package regression tests use it
to verify effect outcomes and balanced active-effect accounting.

## Topics

### Test client

- ``ComposableOTel/TelemetryClient/test(metricReader:errorDetailPolicy:)``
- ``TestCollectors``

### Collectors

- ``InMemorySpanCollector``
- ``InMemoryLogCollector``
- ``InMemoryMetricReader``

### Assertions

- ``InMemorySpanCollector/assertSpanExists(named:withAttributes:file:line:)``
- ``InMemorySpanCollector/assertNoSpan(named:file:line:)``
- ``InMemorySpanCollector/spans(named:)``
- ``InMemoryMetricReader/assertMetricExists(named:file:line:)``
- ``InMemoryMetricReader/assertNoMetric(named:file:line:)``

### Articles

- <doc:TestingGuide>
