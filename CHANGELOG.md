# Changelog

All notable changes to swift-composable-otel. Detailed release notes live in
[RELEASE_NOTES.md](RELEASE_NOTES.md) and migration guidance in [MIGRATION.md](MIGRATION.md).

## 0.5.0

### Added

- Structured TCA lifecycle logs with a stable `event.name` on every record:
  `tca.action.dispatched`, `tca.effect.started`, `tca.effect.completed`, `tca.effect.cancelled`,
  `tca.effect.failed`, `tca.dependency.started`, `tca.dependency.completed`,
  `tca.dependency.failed`, and `tca.navigation.changed` (`ComposableOTelSemantics.LogEvents`).
- Readable fixed log bodies such as `Effect started` and `Dependency call completed`.
- `withTracedRootFlow(feature:flow:operation:)` and
  `Effect.tracedRootRun(feature:effect:priority:operation:)` for explicit root flows.
- `TelemetryDependencyInstrumentation` with `instrument(_:_:)`, `instrumentStream(_:_:)`, and
  `call(_:_:)` for central dependency-client instrumentation.
- `OperationID` presets `.fetch`, `.save`, `.delete`, `.stream`, `.sync`, and `.authorize`.
- Bounded attributes `tca.effect.duration_ms`, `tca.dependency.outcome`,
  `tca.dependency.cancelled`, `tca.dependency.duration_ms`, and `tca.flow.root`.

### Changed

- `tca.feature.name` and reducer trace context propagate into effect, dependency, and navigation
  spans and logs. Lifecycle logs are correlated to the emitting span.
- Navigation spans are parented to the active reducer, effect, or dependency span.
- Dependency `CancellationError` is classified as `cancelled`, not an error.
- Fractional log sampling is decided once at emission, keyed by process session plus per-record
  identity; exporters no longer re-sample.

### Fixed

- The production runtime HTTP clients satisfy the async `HTTPClient` requirement of newer
  `opentelemetry-swift` exporter releases.

## 0.4.0

- Final release of the 0.4.0 line, promoting `0.4.0-rc.6`. See the 0.4.0-rc.6 section of
  [RELEASE_NOTES.md](RELEASE_NOTES.md).
