# Typed External Contracts

Define application-agnostic exact-wire signals without exposing record-time names, attribute
dictionaries, or raw OpenTelemetry handles.

## Register an immutable catalog

A ``TelemetryContractCatalog`` owns one integer contract version plus finite span, bodyless/fixed-body
log, monotonic counter, and resource definitions. A definition fixes its name, exact field keys,
scalar types, allowed enum values or numeric ranges, optionality, and conditional validation rule.

```swift
struct FlowPayload: Sendable {
  let phase: TelemetryEnumValue
  let success: Bool
}

let phase = try TelemetryFieldKey("flow.phase")
let success = try TelemetryFieldKey("flow.success")
let fields: [TelemetryField<FlowPayload>] = [
  try .enumeration(
    phase,
    allowedValues: [try .init("begin"), try .init("end")]
  ) { $0.phase },
  .boolean(success) { $0.success },
]
let span = try TelemetrySpanDefinition(
  name: .init("flow.operation"),
  fields: fields
)
let log = try TelemetryLogDefinition(
  eventName: .init("flow.completed"),
  severity: .info,
  bodyPolicy: .none,
  fields: fields
)
let counter = try TelemetryCounterDefinition(
  name: .init("flow.events"),
  unit: .init("{event}"),
  description: .init("flow-events"),
  maximumSeries: 4,
  fields: fields
)
let catalog = try TelemetryContractCatalog(
  contractVersion: .init(1),
  spans: [.init(span)],
  logs: [.init(log)],
  counters: [.init(counter)]
)
```

Pass the catalog through ``TelemetryPolicy`` at bootstrap. Recording requires the same typed
definition plus its payload:

```swift
try await telemetry.withSpan(span, payload: payload) {
  try telemetry.record(log, payload: payload)
  try telemetry.add(counter, delta: .init(1), payload: payload)
}
```

Every record receives `telemetry.contract.version` exactly once. A definition not registered in the
catalog is rejected. Existing reducer, effect, dependency, and navigation APIs are unchanged.

## Validate conditional fields

Definitions can validate the typed payload and independently validate decoded scalar fields at the
export boundary. Give a conditional rule a stable `validationRule` identifier so it participates in
definition identity. Error-with-code or mutually exclusive fields can therefore be rejected both
before recording and after an unsafe raw SDK attempts to imitate a registered signal.

Counter dimensions must have statically finite cardinality. Enum, bounded integer, and boolean
fields declare finite series; unbounded string/double dimensions are rejected from counter
definitions. ``TelemetryCounterDelta`` accepts positive monotonic increments only.

## Register exact resources

``TelemetryResourceDefinition`` uses the same typed fields and conditional validation.
``TelemetryResourceDefinition/makeValue(_:)`` returns an immutable ``TelemetryResourceValue`` that
can only be used with the catalog containing that exact definition.

``TelemetryDeploymentEnvironment`` is finite: development, test, staging, or production. The
runtime validates the resource definition before creating providers. Extra keys and wrong scalar
types cannot enter through the typed API and are removed at the export boundary.

## Log wire limitation

Registered logs fix EventName, severity, body policy, and typed fields. Bodyless definitions preserve
`body == nil`. The supported OpenTelemetry Swift log builder and `ReadableLogRecord` model do not
contain a severity-text field, so the package cannot currently promise an explicitly empty
`severity_text` value without bypassing the SDK. A contract requiring exact severity text remains
blocked on an upstream model/encoder capability; this package does not add a raw OTLP bypass.

## Delivery and testing

Sanitized span, log, and metric arrays are officially encoded, then recursively split in order before
persistence/transport until every request fits `maximumEncodedRequestBytes`. One record that cannot
fit is a bounded non-retryable drop.

`ComposableOTelTesting` exposes decoded contract spans, logs, delta counters, and resources plus
`InMemoryEncodedRequestCollector` for no-network request assertions.
