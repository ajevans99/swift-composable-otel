# ``ComposableOTel``

OpenTelemetry instrumentation for The Composable Architecture.

## Overview

ComposableOTel provides deep, structured observability for TCA applications
using the [OpenTelemetry](https://opentelemetry.io) standard. It wraps the
[opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift-core)
SDK and exposes TCA-idiomatic APIs for tracing reducers, effects, and
dependency calls.

All telemetry is accessed through a single `@Dependency(\.composableOTel)`
value, making it fully testable and consistent with TCA's dependency
injection patterns.

### Incremental Adoption

You can adopt instrumentation incrementally:

- **Level 1** — Add `.instrumented()` to a reducer for automatic action
  spans and metrics.
- **Level 2** — Use ``Effect/tracedRun(name:priority:operation:)`` for
  full effect lifecycle tracing.
- **Level 3** — Wrap dependency calls with ``tracedCall(_:method:operation:)-8f2j0``
  for per-method span and error tracking.

## Topics

### Essentials

- ``TelemetryClient``
- ``SendableTracer``
- ``InstrumentationOptions``

### Reducer Instrumentation

- ``InstrumentedReducer``

### Effect Tracing

- ``Effect``

### Dependency Call Tracing

- ``tracedCall(_:method:operation:)-8f2j0``
- ``tracedCall(_:method:operation:)-9rj4e``

### Configuration

- ``ErrorDetailPolicy``
- ``SpanAttributeRedactor``
- ``NoOpRedactor``
- ``TCAAttributes``
- ``MetricInstruments``

### Articles

- <doc:GettingStarted>
- <doc:TestingGuide>
