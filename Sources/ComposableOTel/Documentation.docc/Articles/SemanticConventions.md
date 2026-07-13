# Semantic Conventions and Stability

Use package-owned names and bounded identifiers consistently across applications.

## Stability

These conventions are public package API. Before 1.0, documented breaking changes require a minor
release and changelog migration notes. After 1.0, removals or semantic changes follow the
deprecation and major-version policy in `RELEASING.md`. Adding an optional bounded field or a new
instrument is additive; changing a name, unit, meaning, default signal, or cardinality rule is a
behavioral compatibility change.

The conventions are package-generic. Application-specific product names, flows, data
classifications, consent rules, and retention rules do not belong in this package.

The package-specific `tca.*` namespace was reviewed against OpenTelemetry semantic conventions
v1.43.0 on 2026-07-12. `API/SemanticConventions.lock` binds the source declarations to that review.
Adding or renaming a convention requires updating the DocC contract, changelog or migration notes,
the lock, cardinality analysis, API baseline where applicable, and release review. CI fails when the
source changes without that explicit lock update.

## Identifier contract

Every identifier domain has a distinct Swift type and a finite ``TelemetrySchema`` allowlist.
General identifiers are 1 through 48 lowercase ASCII characters using letters, digits, `.`, `_`,
or `-`, and they start with a letter. Service versions also accept a leading digit, uppercase
letters, and `+` for bounded semantic-version prerelease/build syntax.

| Domain | Maximum allowlisted values |
| --- | ---: |
| Features | 32 |
| Actions | 128 |
| Effects | 64 |
| Dependencies | 64 |
| Operations | 128 |
| Routes | 64 |
| Error types/categories/codes | 32 / 32 / 64 |
| Services/versions | 8 / 16 |

Valid but unlisted values and malformed raw SDK values aggregate to `other`. Invalid values loaded
through `init(validating:)` are rejected. Schema overflow throws an error containing only the domain
and limit.

## Traces

Span names are fixed:

- `tca.reducer`
- `tca.effect`
- `tca.dependency`
- `tca.navigation`

Unknown raw SDK names become `otel.span`. Exported events are limited to
`tca.effect.started`, `tca.effect.completed`, `tca.effect.cancelled`, `exception`, and
`tca.navigation.changed`. Unknown events and link attributes are dropped; package exporter wrappers
remove links. Error status text becomes `Operation failed`.

The exporter accepts only the fixed ComposableOTel instrumentation scope name/version with no
schema URL or scope attributes. Spans from other scopes are dropped.

Allowed string attributes are schema-bounded feature, action, effect, dependency, operation, route,
and error identifiers. Allowed booleans describe state change, lifecycle, and error flags. Reducer
duration is a finite nonnegative number capped at one day.

## Logs

Logs are disabled by default. Allowed bodies are fixed to `Action dispatched`, `Effect failed`,
`Dependency call failed`, and `Navigation changed`. Unknown raw bodies become `Telemetry event`.
Log attributes use the same typed allowlist as spans. Unknown event names and attributes are
dropped. Exported scope metadata is rebuilt from the fixed package scope.

## Errors

``TelemetryErrorMetadata`` contains:

- bounded type and category;
- optional bounded code;
- handled and retryable flags.

Raw descriptions, localized text, response bodies, stack traces, backend payloads, and application
state are not accepted. The classifier result passes through the schema before emission.

## Metrics

All package instruments have descriptions and units. Views select the package instrumentation
scope, filter exact dimension keys, apply schema aggregation, and define explicit duration buckets.
A catch-all drop view and the privacy-preserving metric exporter drop unknown instruments.
Export-time filtering is repeated, exemplars are removed, and metrics with unsafe resources are
dropped. Metrics outside the fixed package scope are also dropped.

Maximum series are:

- reducer/action metrics: `(32 + other) * (128 + other) = 4,257`;
- each effect metric: `(64 + other) * 2 = 130`;
- each dependency metric: `(64 + other) * (128 + other) = 8,385`;
- navigation transitions: `(64 + other) * 4 = 260`.

## Resources

Allowed resource attributes are bounded `service.name` and optional `service.version`, fixed
`deployment.environment.name`, `os.type=darwin`, and fixed SDK/distribution identity. Process name,
OS version text, environment resources, and arbitrary host dictionaries are not merged.

## Custom integration trust boundary

``TelemetryClient/unsafeCustomSDK(tracer:metrics:logger:policy:)`` and
``MetricInstruments/unsafeCustomSDK(actionsDispatched:effectsStarted:effectsCompleted:effectsCancelled:effectsErrored:dependenciesCalled:dependenciesErrored:navigationTransitions:reducerDuration:effectDuration:dependencyDuration:activeEffects:)``
are explicit trust boundaries. Custom SDK providers, processors, readers, or exporters can bypass
package enforcement.

Use `ComposableOTelExporters` privacy-preserving exporter wrappers, package metric configuration,
and a resource sanitized with the same ``TelemetryPolicy``. The package does not provide a
raw-payload development mode.

## Registered external contracts

``TelemetryContractCatalog`` can add application-agnostic exact-wire definitions. Each registered
name and key set is part of public compatibility review. Every signal injects one integer
`telemetry.contract.version`; record-time names and raw attributes remain unavailable.

Registered counters are monotonic delta sums with fixed units and finite declared series.
Registered logs can be bodyless with fixed EventName/severity. Exact severity text is not represented
by the supported upstream Swift log model and remains an explicit unsupported wire field rather than
a raw bypass.
