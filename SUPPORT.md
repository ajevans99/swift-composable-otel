# Support Policy

This document defines the supported platform, toolchain, and dependency posture for
`swift-composable-otel`.

## Apple platforms

| Platform | Minimum | Status | Required verification |
| --- | --- | --- | --- |
| iOS | 17.0 | Supported | All products compile for a generic device and the package tests on the current hosted simulator. |
| macOS | 14.0 | Supported | Minimum and latest dependency endpoint builds and tests pass in CI. |
| watchOS | 9.0 | Supported | All products compile for a generic device and platform-relevant contract/runtime tests run on the host. |

The package does not currently make a Linux, tvOS, or visionOS support commitment.

watchOS support covers the typed contracts, telemetry client, production exporters/runtime, and
testing helpers. The current `swift-composable-architecture` 1.26 graph fails a generic watchOS build
at `NotificationName.swift:27:12` because a WatchKit lifecycle notification is main-actor isolated.
The package therefore conditionally excludes its TCA-specific reducer/effect conveniences on watchOS
instead of carrying an upstream fork. The generic operational-event API needed by watch applications
does not depend on that surface.

The latest-dependency CI lane builds every public product for a generic watchOS device. The same lane
runs platform-relevant typed-contract, bounded-queue, privacy, disabled-state, and deletion tests on
the host because SwiftPM package tests are not executable in a standalone watchOS process.

## Swift toolchain

- The manifest uses `swift-tools-version: 6.0`.
- The supported CI baseline is Xcode 16.3 or newer with Swift 6.x.
- Newer Swift 6 toolchains are expected to work, but a release is gated by the CI toolchain
  declared in `.github/workflows/ci.yml`.
- Swift 7 source or language compatibility is not claimed.

## Direct dependencies

| Package | Supported range | Minimum set |
| --- | --- | --- |
| `opentelemetry-swift-core` | `>= 2.4.1, < 3.0.0` | `2.4.1` |
| `opentelemetry-swift` | `>= 2.4.1, < 3.0.0` | `2.4.1` |
| `swift-composable-architecture` | `>= 1.25.0, < 2.0.0` | `1.25.0` |
| `swift-dependencies` | `>= 1.5.1, < 2.0.0` | `1.5.1` |
| `xctest-dynamic-overlay` | `>= 1.9.0, < 2.0.0` | `1.9.0` |
| `swift-sharing` | `== 2.8.2` | `2.8.2` |

`Package.swift` is authoritative for dependency constraints. Documentation must be updated in the
same pull request whenever a bound changes.

CI resolves and tests two dependency sets:

- **Minimum:** pins each direct dependency to the lower bound above, then builds and tests on
  macOS with Xcode 16.3.
- **Latest:** resolves the newest versions allowed by `Package.swift`, then builds and tests on
  macOS, builds every product for generic iOS and watchOS devices, and runs package tests on the
  current hosted iOS simulator with the current Xcode.

The GitHub-hosted macOS 15 image does not install Xcode 16.3's iOS 18.4 platform, so that
lane cannot select a generic iOS destination. The current-Xcode lane remains the required iOS
build/test gate; the unavailable historical SDK is not treated as a package source failure.

The two lanes are supported endpoints rather than an unsupported four-way cross-product:

| Toolchain | Minimum dependencies | Latest compatible dependencies |
| --- | --- | --- |
| Xcode 16.3 | Required macOS build/test. Its hosted image lacks the Xcode 16.3 iOS 18.4 platform. | Not claimed; newer resolved packages may require a newer compiler. |
| Current Xcode | Not claimed; the local Swift 6.4 probe fails TCA 1.25's `PresentsMacro.swift:225` because SwiftSyntax 600's `GenericArgumentSyntax` has no member `Argument`. | Required macOS build/test, generic iOS builds, and current iOS simulator tests. |

Package deployment targets remain iOS 17, macOS 14, and watchOS 9 even when hosted runners no longer
offer those exact simulator/runtime versions. Generic builds compile against the declared deployment
floors; runtime tests execute on the hosted SDKs actually listed by CI.

The minimum job catches accidental use of newer APIs. The latest job catches upstream
compatibility regressions. A dependency update that fails either set is not supported until the
constraint, implementation, or documented support range is deliberately changed.

TCA permits all `swift-sharing` 2.x releases. The package constrains `swift-sharing` to 2.8.2, the
final release before 2.9 enabled cross-package traits on `swift-dependencies`. A tools-version 6.0
root selects the dependency's 6.0 compatibility manifest, which does not declare those traits. The
constraint keeps the published package graph coherent; it can be removed when the supported tools
version can consume those traits.

## Quality support gates

- Thread Sanitizer runs the full macOS suite on the current toolchain. iOS simulator TSan is not
  claimed by this package matrix.
- Coverage floors are 90% for `ComposableOTel`, 80% for `ComposableOTelExporters`, 50% for
  `ComposableOTelTesting`, and 80% for `TelemetryRuntime*` delivery paths.
- `API/PublicAPI.json` blocks public symbol removal or signature change until the reviewed baseline
  deliberately changes. Additions are reported.
- `API/SemanticConventions.lock` binds package convention sources to the reviewed OpenTelemetry
  semantic conventions v1.43.0 snapshot. Convention changes require a lock and documentation review.
- Release performance, memory, batching, and queue ceilings are documented in `PERFORMANCE.md`.

Default-branch protection and required-check configuration are repository administration evidence,
not package code. They remain required before 1.0.

## Upstream exact-log limitation

OpenTelemetry Swift's supported `LogRecordBuilder` and `ReadableLogRecord` do not expose severity
text. Registered definitions can guarantee EventName, severity, nil/fixed body, typed fields, and
contract version, but cannot guarantee an explicitly empty `severity_text`. A release contract that
requires that exact field remains unsupported until the upstream model/encoder adds it.

## Public SDK boundary

Normal products intentionally omit raw SDK client/instrument factories, dictionary sanitizer
methods, privacy exporter wrappers, and metric-view builders. Swift package-access hooks support
internal exporter/testing targets. CI checks the public symbol graph and compiles a negative consumer
fixture that must fail when referencing those implementation symbols.

## `Package.resolved`

The repository intentionally does not commit a root `Package.resolved`. This is a library package,
so applications integrating it own the final dependency graph. CI removes any local lockfile and
materializes a fresh minimum or latest resolution before building. Release review must confirm
that `Package.resolved` remains untracked.

## Support changes

Raising a minimum platform, toolchain, or dependency version is a compatibility change. Before
1.0 it requires at least a minor release and a changelog entry. After 1.0 it requires a major
release unless an urgent correctness or security constraint makes the old range unusable.
