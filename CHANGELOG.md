# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) with the pre-1.0 policy in
[RELEASING.md](RELEASING.md).

## [Unreleased]

## [0.3.1] - 2026-07-15

### Fixed

- `TelemetryRuntime` can now explicitly opt into plain HTTP for local simulator OTLP development,
  but only when its resource environment is development or test and every signal endpoint host is
  loopback. HTTPS remains the default, while staging, production, LAN, non-loopback, and mixed
  local/remote endpoint configurations remain rejected.
- Documentation validation now accepts the populated `Unreleased` section required by the
  repository's changelog policy.

## [0.3.0] - 2026-07-13

### Added

- Central package and OpenTelemetry instrumentation metadata.
- An explicit MIT repository license.
- Explicit platform, dependency, versioning, deprecation, and release policies.
- CI validation for supported Apple platforms, minimum/latest dependency sets, package metadata,
  and documentation.
- Task-local-safe reducer, effect, and dependency span activation with explicit
  reducer-to-effect parenting.
- Consistent success, cancelled, and error outcomes for one-shot and long-lived effects.
- Typed, validated identifiers and finite schema allowlists for features, actions, effects,
  dependencies, operations, routes, errors, services, and service versions.
- Privacy-preserving span, log, and metric exporter wrappers; bounded metric views, descriptions,
  units, histograms, and explicit series limits.
- Independent trace, metric, and log controls with logs disabled by default.
- Stable package semantic conventions and navigation transition telemetry.
- A lifecycle-owning production `TelemetryRuntime` for traces, metrics, and logs with validated
  OTLP/HTTP TLS endpoints and per-attempt host authentication.
- Bounded off-main batching, retry/backoff/jitter, request timeouts, reachability hints, structured
  flush/shutdown results, lifecycle hooks, and non-recursive exporter diagnostics.
- Optional atomic OTLP persistence with age/size limits, Apple file protection, backup exclusion,
  relaunch recovery, and corruption removal.
- Deterministic concurrency stress, target/runtime coverage floors, TSan, public API compatibility,
  semantic-convention review, and release performance/memory/queue gates.
- A configurable encoded OTLP request ceiling with pre-persistence oversized-request diagnostics,
  plus bounded numeric `Retry-After` response metadata.
- An immutable typed external contract catalog for exact custom spans, bodyless EventName logs,
  monotonic delta counters, conditional fields, and schema-matched resources.
- Separate native and strict resource modes plus an independent registered custom-metric point cap.
- Current iOS simulator testing plus migration, privacy, security, operations, pilot-evidence, and
  explicit 1.0 go/no-go guidance.
- An idempotent consent-revocation operation that skips flush, cancels delivery, permanently stops
  the runtime, and deletes all unsent in-memory and persisted telemetry.

### Changed

- Corrected installation, compatibility, testing, state, error, sampling, logging, metric, and
  exporter documentation to match current behavior.
- Identified package bootstrap metadata as an OpenTelemetry distribution without overwriting the
  SDK's own identity.
- Effect tracing now preserves errors and cancellation, uses structured cleanup for balanced
  active-effect accounting, and traces long-lived work with one lifecycle span.
- Renamed marker-only effect instrumentation to `.traceStart()` and deprecated `.traced()`.
- `TelemetryClient` now caches an injected logger and uses provider-independent no-op defaults.
- Bootstrap is thread-safe and first-configuration-wins idempotent; test clients no longer mutate
  global OpenTelemetry providers.
- Reducer, effect, dependency, and navigation spans now use fixed low-cardinality names. Identifier
  values outside the configured schema aggregate to `other`.
- Reducer instrumentation now requires explicit feature/action IDs. Optional state-change reporting
  compares opaque host tokens and never creates state descriptions.
- Error telemetry now exports only bounded type/category/code and handled/retryable fields with
  generic status and log text.
- Test clients install the same privacy wrappers and metric views as package bootstrap.
- Bootstrap now keeps its privacy-preserving providers isolated instead of replacing OpenTelemetry
  process globals and affecting unrelated instrumentation.
- The published manifest constrains `swift-sharing` to the final tools-6.0-compatible release
  before cross-package dependency traits.
- Production composition now uses an owned `TelemetryRuntime`; `TelemetryBootstrap` is an explicit
  development-only stdout helper.
- Reducer duration is measured once and reused across its span, metric, and log.
- HTTP 401 and 413 are explicitly terminal, while 429 honors host-parsed numeric `Retry-After` up to
  the configured maximum backoff.
- Production resource environments are now a finite typed value instead of a hardcoded production
  label and have one source in native or strict resource mode; the runtime default remains
  production.
- Caught errors remain successful native/custom operations unless the host explicitly records a
  registered typed handled-error log.
- Catalog membership now uses opaque registration identities, custom definitions reject native
  signal names, disabled clients preserve sync/async operation semantics, and metric exporters
  enforce actual point counts in addition to catalog series bounds.
- Bootstrap and test-client creation now throw when a strict resource value is not registered,
  before any provider is created.

### Migration

The complete `0.2.2` to `0.3.0` migration is in [MIGRATION.md](MIGRATION.md). In summary:

- replace reflection-derived names with typed schema identifiers;
- replace `.traced()` with `.traceStart(effect:)` or a lifecycle-traced effect;
- replace `configureTestTelemetry` with `TelemetryClient.test(metricReader:policy:)`;
- replace `ErrorDetailPolicy` and `SpanAttributeRedactor` with bounded
  `TelemetryPolicy.classifyError`; and
- replace production bootstrap headers with a retained `TelemetryRuntime` and per-attempt
  authenticator.

### Removed

- Reflection-derived reducer/action names, arbitrary string effect/dependency APIs, state
  `String(describing:)` comparison, arbitrary `TelemetryClient` log bodies/attributes, and the
  unenforced `ErrorDetailPolicy`/`SpanAttributeRedactor` APIs.
- The deprecated global `configureTestTelemetry` helper and marker-only `.traced()` spelling.
- The unused `.production(endpoint:headers:)` stdout bootstrap placeholder. Production callers
  migrate to `TelemetryRuntime` with a host transport and short-lived request authenticator.
- Public raw SDK client/instrument factories, dictionary sanitizer methods, privacy exporter
  wrappers, and metric view configuration from normal products. Cross-target wiring is package-only.

### Fixed

- The split-encoding failure-isolation test now invokes the synchronous exporter dispatcher from a
  dedicated queue, matching its production execution context instead of blocking Swift Testing's
  cooperative executor. macOS CI test steps now have a 10-minute timeout as bounded
  defense-in-depth.
- The release policy now requires the named watchOS support gate to pass for 1.0; documented
  unsupported status remains available only to pre-1.0 releases.

### Security

- Allowlist-first filtering now covers span names/attributes/events/links/status, log
  bodies/attributes/event names, metric instruments/dimensions/exemplars, and resource attributes
  before package-owned exporters receive data.
- Production endpoints reject non-TLS URLs and embedded credentials. Authorization is acquired for
  each attempt and is never persisted; sanitized telemetry is enforced before queues, disk, and
  network delivery.
- Hosts can swap to `TelemetryClient.noop` and atomically disable/discard a production runtime;
  filesystem deletion failures are surfaced and retryable without resuming export.

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

[Unreleased]: https://github.com/ajevans99/swift-composable-otel/compare/0.3.1...HEAD
[0.3.1]: https://github.com/ajevans99/swift-composable-otel/compare/0.3.0...0.3.1
[0.3.0]: https://github.com/ajevans99/swift-composable-otel/compare/0.2.2...0.3.0
[0.2.2]: https://github.com/ajevans99/swift-composable-otel/compare/0.2.1...0.2.2
[0.2.1]: https://github.com/ajevans99/swift-composable-otel/compare/0.2.0...0.2.1
[0.2.0]: https://github.com/ajevans99/swift-composable-otel/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/ajevans99/swift-composable-otel/tree/0.1.0
