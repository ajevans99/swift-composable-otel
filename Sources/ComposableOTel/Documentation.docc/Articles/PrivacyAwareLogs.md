# Privacy-aware interpolated logs

Write useful prose while keeping dynamic values private unless their type is explicitly approved.

## Record a message

Enable logs in ``TelemetrySignalConfiguration`` and call ``TelemetryClient/log(_:_:)``:

```swift
let planID = response.planID

telemetry.log(
  .info,
  "Plan \(planID) save finished with \(TelemetryOutcome.success, privacy: .public)"
)
```

`planID` is private because it has no annotation. ``TelemetryLogMessage`` replaces it with
``TelemetryLogMessage/redactionToken`` during interpolation construction and never evaluates or
retains the original value. The public outcome is a finite package enum.

## Understand the wire record

Every accepted message exports:

- the stable `app.log` event name;
- a canonical escaped template and deterministic template identity;
- a safely rendered body;
- info or error severity;
- ordered, typed public values; and
- active OpenTelemetry trace/span context when present.

The template uses fixed private and typed-public placeholders, so changing an interpolation value
does not change template identity. Before any observer, production queue, OTLP exporter, persistence
store, or testing collector retains the record, the package validates the shape, schema-bounds
identifier values, and rebuilds the body from the template and typed public fields.

## Choose public values deliberately

`privacy: .public` is available only for concrete package identifier domains, finite package enums,
`Bool`, ``TelemetryLogInteger``, ``TelemetryLogDuration``, ``TelemetryLogCountBucket``, and
``TelemetryCorrelationID``. It is unavailable for strings, errors, URLs, arbitrary descriptions,
contract strings, and consumer-defined identifier kinds.

Concrete identifier values still pass through ``TelemetrySchema``. A valid value outside the schema
renders and exports as `other`.

## Handle bounds and acceptance

Templates are limited to 512 UTF-8 bytes, rendered bodies to 1,024 UTF-8 bytes, interpolations to 16,
and public values to 8. ``TelemetryClient/log(_:_:)`` returns ``TelemetryLogRecordingResult``
synchronously. Invalid messages never enter telemetry. Runtime `.recorded` means the bounded queue
accepted the record; delivery remains best-effort.

Private local rendering is not supported. This is intentionally deferred so a development switch
cannot weaken the shared boundary used by observers, persistence, tail buffers, or OTLP.
