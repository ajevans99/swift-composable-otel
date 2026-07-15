# Typed External Contracts

Define application-agnostic exact-wire signals without exposing record-time names, attribute
dictionaries, or raw OpenTelemetry handles.

## Register an immutable catalog

A ``TelemetryContractCatalog`` owns one integer contract version plus finite span,
bodyless/fixed-body log, bodyless operational-event, monotonic counter, and resource definitions. A
definition fixes its name, exact field keys, scalar types, allowed enum values or numeric ranges,
optionality, and conditional validation rule.

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
let event = try TelemetryOperationalEventDefinition(
  eventName: .init("flow.event"),
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
  operationalEvents: [.init(event)],
  counters: [.init(counter)]
)
```

Pass the catalog through ``TelemetryPolicy`` at bootstrap. Recording requires the same typed
definition plus its payload:

```swift
try await telemetry.withSpan(span, payload: payload) {
  try telemetry.record(log, payload: payload)
  telemetry.record(event, payload: payload)
  try telemetry.add(counter, delta: .init(1), payload: payload)
}
```

Every record receives `telemetry.contract.version` exactly once. Registration carries an opaque
identity, so rebuilding a structurally identical definition does not forge catalog membership.
Custom definitions cannot reserve package-owned span, event, or metric names. A definition not
registered in the catalog is rejected. Existing reducer, effect, dependency, and navigation APIs are
unchanged.

``TelemetryClient/withSynchronousSpan(_:payload:operation:)`` preserves synchronous execution;
``TelemetryClient/withSpan(_:payload:operation:)`` preserves async execution. Disabled and no-op
clients execute either operation unchanged and make log/counter/operational-event recording a no-op.

Operational events are bodyless info records. Enable them with
`TelemetrySignalConfiguration(operationalEventsEnabled: true)`. This is independent from
`logsEnabled`, so registered operational events do not enable package-owned action, navigation, or
error logs. `TelemetryClient.record(_:payload:)` validates and inserts an operational event into
the runtime's bounded log queue before returning; export remains asynchronous. It is nonthrowing and
returns ``TelemetryOperationalEventRecordingResult`` so callers and tests can distinguish recorded,
disabled, overflow-dropped, and contract-rejected events without coupling sync behavior to telemetry
success. Contract rejection fails closed and increments the runtime log dropped-item diagnostic.
Field extraction closures are nonthrowing; returning `nil` for a required field rejects the payload.

## Validate conditional fields

Definitions can validate the typed payload and independently validate decoded scalar fields at the
export boundary. Give a conditional rule a stable `validationRule` identifier so it participates in
definition identity. Error-with-code or mutually exclusive fields can therefore be rejected both
before recording and after an unsafe raw SDK attempts to imitate a registered signal.

Integer field ranges must fit signed 32-bit values so one registered contract has identical behavior
on iOS, macOS, and watchOS.

Counter dimensions must have statically finite cardinality. Enum, bounded integer, and boolean
fields declare finite series; unbounded string/double dimensions are rejected from counter
definitions. ``TelemetryCounterDelta`` accepts positive monotonic increments only.

## Register exact resources

``TelemetryResourceDefinition`` uses the same typed fields and conditional validation.
``TelemetryResourceDefinition/makeValue(_:)`` returns an immutable ``TelemetryResourceValue`` that
can only be used with the catalog containing that exact definition.

``TelemetryDeploymentEnvironment`` is finite: development, test, staging, or production.
`TelemetryResourceMode.native(environment:)` preserves the existing
service/environment/Darwin/SDK/distribution
resource. `TelemetryResourceMode.strict(_:)` emits only required registered fields plus contract
version. Strict resource definitions cannot contain optional fields and must include exactly one
bounded deployment environment in the resource value. Extra keys and wrong scalar types are rejected
before providers.

## Log wire limitation

Registered logs fix EventName, severity, body policy, and typed fields. Bodyless definitions preserve
`body == nil`. The supported OpenTelemetry Swift log builder and `ReadableLogRecord` model do not
contain a severity-text field, so the package cannot currently promise an explicitly empty
`severity_text` value without bypassing the SDK. A contract requiring exact severity text remains
blocked on an upstream model/encoder capability; this package does not add a raw OTLP bypass.

Error classification follows observed control flow. An error that escapes a registered span receives
generic error status/event handling. If an operation catches an error and returns success, the span
remains successful; record a registered bodyless handled-error log explicitly instead of
reinterpreting the successful operation.

## Delivery and testing

Sanitized span, log, and metric arrays are officially encoded, then recursively split in order before
persistence/transport until every request fits `maximumEncodedRequestBytes`. One record that cannot
fit is a bounded non-retryable drop.

`maximumContractMetricPointsPerRequest` independently bounds the sum of registered counter maximum
series in one custom collection (50 by default). Runtime creation rejects a catalog above the cap,
and the exporter independently partitions metric records by actual point count. A single metric
record above the cap is dropped without transport and produces a bounded diagnostic.

`ComposableOTelTesting` exposes decoded contract spans, logs, operational events, delta counters,
and resources plus `InMemoryEncodedRequestCollector` for no-network request assertions.
