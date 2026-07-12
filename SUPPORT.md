# Support Policy

This document defines the supported platform, toolchain, and dependency posture for
`swift-composable-otel`.

## Apple platforms

| Platform | Minimum | Status | Required verification |
| --- | --- | --- | --- |
| iOS | 17.0 | Supported | All products compile for a generic iOS device in CI. |
| macOS | 14.0 | Supported | `swift build` and `swift test` pass in CI. |
| watchOS | 10.0 intended | Unsupported | The watchOS support gate below must pass before support is declared. |

The package does not currently make a Linux, tvOS, or visionOS support commitment.

### watchOS support gate

watchOS remains unsupported until one change:

1. Declares `.watchOS(.v10)` in `Package.swift`.
2. Demonstrates that every public library product and all required dependencies compile for a
   generic watchOS device.
3. Adds a maintained watchOS CI job and a simulator- or host-based strategy that exercises the
   platform-relevant test surface.
4. Documents lifecycle, exporter, and background-execution limits specific to watchOS.

A successful ad hoc build alone does not satisfy this gate.

## Swift toolchain

- The manifest uses `swift-tools-version: 6.0`.
- The supported CI baseline is Xcode 16.3 or newer with Swift 6.x.
- Newer Swift 6 toolchains are expected to work, but a release is gated by the CI toolchain
  declared in `.github/workflows/ci.yml`.
- Swift 7 source or language compatibility is not claimed.

## Direct dependencies

| Package | Supported range | Minimum set |
| --- | --- | --- |
| `opentelemetry-swift-core` | `>= 2.3.0, < 3.0.0` | `2.3.0` |
| `swift-composable-architecture` | `>= 1.17.0, < 2.0.0` | `1.17.0` |
| `swift-dependencies` | `>= 1.4.0, < 2.0.0` | `1.4.0` |
| `xctest-dynamic-overlay` | `>= 1.9.0, < 2.0.0` | `1.9.0` |

`Package.swift` is authoritative for dependency constraints. Documentation must be updated in the
same pull request whenever a bound changes.

CI resolves and tests two dependency sets:

- **Minimum:** pins each direct dependency to the lower bound above.
- **Latest:** resolves the newest versions allowed by `Package.swift`.

The minimum job catches accidental use of newer APIs. The latest job catches upstream
compatibility regressions. A dependency update that fails either set is not supported until the
constraint, implementation, or documented support range is deliberately changed.

## `Package.resolved`

The repository intentionally does not commit a root `Package.resolved`. This is a library package,
so applications integrating it own the final dependency graph. CI removes any local lockfile and
materializes a fresh minimum or latest resolution before building. Release review must confirm
that `Package.resolved` remains untracked.

## Support changes

Raising a minimum platform, toolchain, or dependency version is a compatibility change. Before
1.0 it requires at least a minor release and a changelog entry. After 1.0 it requires a major
release unless an urgent correctness or security constraint makes the old range unusable.
