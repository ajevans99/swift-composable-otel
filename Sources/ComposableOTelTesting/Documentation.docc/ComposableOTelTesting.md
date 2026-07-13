# ``ComposableOTelTesting``

Inspect bounded ComposableOTel signals with isolated in-memory collectors.

## Overview

Use
``ComposableOTel/TelemetryClient/test(metricReader:contractMetricReader:deploymentEnvironment:resource:policy:)``
with the same policy as the
application. Test clients install the production span/log privacy wrappers and package metric
views, own local providers, and never replace process-global OpenTelemetry providers.

``TestCollectors`` exposes spans, logs, and the optional metric reader. Call
``TestCollectors/forceFlush()`` before assertions.

For registered contracts, use decoded span/log/counter/resource helpers and
``InMemoryEncodedRequestCollector``. Captures preserve scalar wire types and contract version without
exposing production credentials or performing network I/O.

## Topics

### Test client

- ``ComposableOTel/TelemetryClient/test(metricReader:contractMetricReader:deploymentEnvironment:resource:policy:)``
- ``TestCollectors``

### Collectors

- ``InMemorySpanCollector``
- ``InMemoryLogCollector``
- ``InMemoryMetricReader``
- ``InMemoryEncodedRequestCollector``
- ``DecodedContractSpan``
- ``DecodedContractLog``
- ``DecodedContractCounter``
- ``DecodedContractResource``

### Assertions

- ``InMemorySpanCollector/assertSpanExists(named:withAttributes:file:line:)``
- ``InMemorySpanCollector/assertNoSpan(named:file:line:)``
- ``InMemorySpanCollector/spans(named:)``
- ``InMemoryMetricReader/assertMetricExists(named:file:line:)``
- ``InMemoryMetricReader/assertNoMetric(named:file:line:)``

### Articles

- <doc:TestingGuide>
