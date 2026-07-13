# Testing Guide

Exercise the same privacy boundary used by package bootstrap.

## Create a client

```swift
let schema = try! TelemetrySchema(
  features: ["library"],
  actions: ["refresh"],
  services: ["test-suite"]
)
let policy = TelemetryPolicy(schema: schema)
let reader = InMemoryMetricReader()
let (telemetry, collectors) = TelemetryClient.test(
  metricReader: reader,
  policy: policy
)
```

Inject `telemetry` into TCA dependencies. The client owns isolated providers and installs package
privacy wrappers and metric views.

## Inspect spans

```swift
await store.send(.refresh)
collectors.forceFlush()

collectors.spans.assertSpanExists(
  named: "tca.reducer",
  withAttributes: ["tca.action.name": "refresh"]
)

let effectSpans = collectors.spans.spans(named: "tca.effect")
```

Span names are stable; distinguish operations with bounded attributes.

## Inspect logs

Enable logs explicitly:

```swift
let signals = TelemetrySignalConfiguration(logsEnabled: true)
let policy = TelemetryPolicy(schema: schema, signals: signals)
```

```swift
let errors = collectors.logs.records(withSeverity: .error)
let failures = collectors.logs.records(containing: "Dependency call failed")
```

Log bodies remain fixed. Assert bounded attributes rather than payload text.

## Inspect metrics

```swift
collectors.forceFlush()
let actions = reader.metrics(named: "tca.actions.dispatched")
```

Collected metrics include package descriptions, units, views, bounded dimensions, and explicit
duration buckets.

## Inspect registered contracts

Create a test client with a policy containing the same `TelemetryContractCatalog` and optional
resource value as production.
`TestCollectors` can decode exact registered fields:

```swift
collectors.forceFlush()
let spans = collectors.decodedSpans(for: spanDefinition)
let logs = collectors.decodedLogs(for: logDefinition)
let counters = collectors.decodedCounters(for: counterDefinition)
let resource = collectors.decodedResource(for: resourceDefinition)
```

Assert exact field sets and ``TelemetryDecodedScalar`` cases, integer contract version, nil log body,
fixed EventName/severity, delta counter temporality/unit/value, and resource environment.

Use ``InMemoryEncodedRequestCollector`` as the production runtime transport to inspect encoded
request signal/body size without network access.

## Leakage and cardinality tests

Place sentinel values in action associated values, custom descriptions, state descriptions, errors,
raw log bodies, resources, raw attributes, events, status, URLs, and metric dimensions. Encode
collected data and assert the sentinel never appears. Generate many valid-but-unlisted identifiers
and assert they aggregate to one `other` series while span and instrument names stay fixed.
