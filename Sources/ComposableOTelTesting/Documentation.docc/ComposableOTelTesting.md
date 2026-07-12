# ``ComposableOTelTesting``

In-memory helpers for inspecting ComposableOTel instrumentation.

## Overview

Use ``ComposableOTel/TelemetryClient/test(metricReader:errorDetailPolicy:)`` to create a client
and ``TestCollectors``. Inject the client through TCA dependencies, exercise the feature, call
``TestCollectors/forceFlush()``, and inspect spans or logs.

The factory registers process-global OpenTelemetry providers. Telemetry tests must run serially.
The optional in-memory metric reader is provisional in `0.2.2` and is not covered by the package
regression suite.

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
