# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) with the pre-1.0 policy in
[RELEASING.md](RELEASING.md).

## [Unreleased]

### Added

- Central package and OpenTelemetry instrumentation metadata.
- An explicit MIT repository license.
- Explicit platform, dependency, versioning, deprecation, and release policies.
- CI validation for supported Apple platforms, minimum/latest dependency sets, package metadata,
  and documentation.

### Changed

- Corrected installation, compatibility, testing, state, error, sampling, logging, metric, and
  exporter documentation to match current behavior.
- Identified package bootstrap metadata as an OpenTelemetry distribution without overwriting the
  SDK's own identity.

## [0.2.2] - 2026-04-15

### Added

- `TestCollectors.forceFlush()` for flushing pending spans before assertions.

## [0.2.1] - 2026-04-15

### Changed

- Assertion helpers now report through `IssueReporting`, allowing use from application test
  targets without a direct XCTest dependency.

## [0.2.0] - 2026-04-15

### Added

- OpenTelemetry logger-provider bootstrap.
- In-memory log collection and query helpers.

## [0.1.0] - 2026-04-15

### Added

- Initial reducer, effect, and dependency-call tracing APIs.
- Reducer, effect, and dependency metrics.
- Dependency-injected `TelemetryClient` and in-memory test helpers.
- Stdout SDK bootstrap, DocC catalogs, formatting configuration, and macOS CI.

[Unreleased]: https://github.com/ajevans99/swift-composable-otel/compare/0.2.2...HEAD
[0.2.2]: https://github.com/ajevans99/swift-composable-otel/compare/0.2.1...0.2.2
[0.2.1]: https://github.com/ajevans99/swift-composable-otel/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/ajevans99/swift-composable-otel/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ajevans99/swift-composable-otel/tree/0.1.0
