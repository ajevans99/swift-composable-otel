# ``ComposableOTel``

Instrument The Composable Architecture with OpenTelemetry signals.

## Overview

ComposableOTel provides dependency-injected APIs for reducer spans, effect lifecycle signals,
dependency-call spans, structured logs, and metrics.

The current release is a pre-1.0 instrumentation prototype. Reducer spans cover synchronous
reducer execution only. ``ComposableArchitecture/Effect/traced(name:)`` emits an initiation
marker, while ``ComposableArchitecture/Effect/tracedRun(name:priority:operation:)`` wraps an
operation but consumes cancellation and other thrown errors after recording telemetry. Logs
resolve through the global OpenTelemetry logger provider. ``SpanAttributeRedactor`` is not yet
invoked.

`ComposableOTelExporters` configures stdout export only. Its production endpoint and headers do
not send remote OTLP telemetry in this release.

### Incremental adoption

- Add ``ComposableArchitecture/Reducer/instrumented(name:options:)`` for reducer spans, optional
  action logs, and metrics.
- Use ``ComposableArchitecture/Effect/tracedRun(name:priority:operation:)`` when its current error
  behavior is acceptable.
- Wrap dependency methods with `tracedCall` for per-call spans and metrics.
- Override `@Dependency(\.composableOTel)` with a test client from `ComposableOTelTesting`.

## Topics

### Essentials

- ``TelemetryClient``
- ``SendableTracer``
- ``ComposableOTelMetadata``
- ``InstrumentationOptions``

### Reducer instrumentation

- ``InstrumentedReducer``
- ``ComposableArchitecture/Reducer/instrumented(name:options:)``

### Effect tracing

- ``ComposableArchitecture/Effect/traced(name:)``
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
