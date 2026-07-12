# ``ComposableOTelTesting``

Inspect bounded ComposableOTel signals with isolated in-memory collectors.

## Overview

Use ``ComposableOTel/TelemetryClient/test(metricReader:policy:)`` with the same policy as the
application. Test clients install the production span/log privacy wrappers and package metric
views, own local providers, and never replace process-global OpenTelemetry providers.

``TestCollectors`` exposes spans, logs, and the optional metric reader. Call
``TestCollectors/forceFlush()`` before assertions.

## Topics

### Test client

- ``ComposableOTel/TelemetryClient/test(metricReader:policy:)``
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
