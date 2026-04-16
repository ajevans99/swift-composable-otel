# ``ComposableOTelTesting``

Test utilities for verifying OpenTelemetry instrumentation.

## Overview

This module provides in-memory collectors and assertion helpers
for testing TCA features instrumented with ComposableOTel.

Use ``TelemetryClient/test(spanCollector:metricReader:errorDetailPolicy:)``
to create a fully-wired test client, then inject it via
`withDependencies`.

## Topics

### Test Client

- ``TelemetryClient``

### Collectors

- ``InMemorySpanCollector``
- ``InMemoryMetricReader``

### Assertions

- ``InMemorySpanCollector/assertSpanExists(named:file:line:)``
- ``InMemorySpanCollector/assertNoSpan(named:file:line:)``
- ``InMemorySpanCollector/spans(named:)``
