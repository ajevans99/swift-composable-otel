# ``ComposableOTel``

Instrument The Composable Architecture with bounded, privacy-safe OpenTelemetry signals.

## Overview

ComposableOTel emits fixed-name reducer, effect, dependency, and navigation spans plus bounded
metrics and optional fixed-body logs. Applications provide a finite ``TelemetrySchema`` and typed
identifiers. Unknown values aggregate to `other`; invalid dynamic values cannot become telemetry
identifiers.

The default ``TelemetrySignalConfiguration`` enables traces and metrics independently and disables
logs. Reducer actions and state are never reflected. Optional state-change reporting compares
non-exported ``StateChangeToken`` values. Errors expose only schema-bounded metadata from
``TelemetryErrorMetadata`` and generic status/log text.

`ComposableOTelExporters` supplies the development stdout bootstrap plus a lifecycle-owning
production `TelemetryRuntime` with bounded OTLP/HTTP delivery. Both install the same
exporter-boundary filtering and metric views.

### Adoption

- Define a ``TelemetrySchema`` and ``TelemetryPolicy``.
- Add `Reducer.instrumented(feature:action:stateChangeToken:)`.
- Use `Effect.tracedRun(effect:priority:operation:)` or
  `Effect.tracedLongLivedRun(effect:priority:operation:)`.
- Use `tracedCall(dependency:operation:operation:)` for dependency work.
- Call ``TelemetryClient/recordNavigation(_:route:)`` with route names that contain no parameters.
- Test through `ComposableOTelTesting`.

## Topics

### Policy and identifiers

- ``TelemetrySchema``
- ``TelemetryPolicy``
- ``TelemetryIdentifier``
- ``TelemetrySignalConfiguration``
- ``TelemetryErrorMetadata``
- ``TelemetryOutcome``
- ``NavigationOperation``
- ``StateChangeToken``

### Runtime

- ``TelemetryClient``
- ``MetricInstruments``
- ``ComposableOTelMetadata``
- ``ComposableOTelSemantics``
- ``TCAAttributes``

### Reducers and effects

- ``InstrumentedReducer``
- ``ComposableArchitecture/Reducer/instrumented(feature:action:stateChangeToken:)``
- ``ComposableArchitecture/Effect/traceStart(effect:)``
- ``ComposableArchitecture/Effect/tracedRun(effect:priority:operation:)``
- ``ComposableArchitecture/Effect/tracedLongLivedRun(effect:priority:operation:)``

### Articles

- <doc:GettingStarted>
- <doc:SemanticConventions>
