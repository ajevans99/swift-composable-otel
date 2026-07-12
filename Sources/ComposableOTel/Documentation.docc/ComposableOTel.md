# ``ComposableOTel``

Instrument The Composable Architecture with OpenTelemetry signals.

## Overview

ComposableOTel provides dependency-injected APIs for reducer spans, effect lifecycle signals,
dependency-call spans, structured logs, and metrics.

The current release is a pre-1.0 instrumentation prototype. Reducer spans cover synchronous
reducer execution and use closure-based task-local activation. Traced effects created during
reduction capture the reducer span as their explicit parent, then use their own active span across
suspension and inherited child tasks. Effect failures and cancellation are recorded and rethrown.
Logs use the logger stored by the injected ``TelemetryClient``. ``SpanAttributeRedactor`` is not
yet invoked.

`ComposableOTelExporters` configures stdout export only. Its production endpoint and headers do
not send remote OTLP telemetry in this release.

### Incremental adoption

- Add ``ComposableArchitecture/Reducer/instrumented(name:options:)`` for reducer spans, optional
  action logs, and metrics.
- Use ``ComposableArchitecture/Effect/tracedRun(name:priority:operation:)`` for one-shot effect
  lifecycle outcomes.
- Use ``ComposableArchitecture/Effect/traceStart(name:)`` only when an initiation marker is enough.
- Wrap dependency methods with `tracedCall` for per-call spans and metrics.
- Override `@Dependency(\.composableOTel)` with a test client from `ComposableOTelTesting`.

## Topics

### Essentials

- ``TelemetryClient``
- ``SendableTracer``
- ``SendableLogger``
- ``ComposableOTelMetadata``
- ``InstrumentationOptions``

### Reducer instrumentation

- ``InstrumentedReducer``
- ``ComposableArchitecture/Reducer/instrumented(name:options:)``

### Effect tracing

- ``ComposableArchitecture/Effect/traced(name:)``
- ``ComposableArchitecture/Effect/traceStart(name:)``
- ``ComposableArchitecture/Effect/tracedRun(name:priority:operation:)``
- ``ComposableArchitecture/Effect/tracedLongLivedRun(name:priority:operation:)``

### Configuration

- ``ErrorDetailPolicy``
- ``SpanAttributeRedactor``
- ``NoOpRedactor``
- ``TCAAttributes``
- ``MetricInstruments``

### Articles

- <doc:GettingStarted>
