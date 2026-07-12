// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "swift-composable-otel",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(name: "ComposableOTel", targets: ["ComposableOTel"]),
    .library(name: "ComposableOTelExporters", targets: ["ComposableOTelExporters"]),
    .library(name: "ComposableOTelTesting", targets: ["ComposableOTelTesting"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/open-telemetry/opentelemetry-swift-core.git",
      from: "2.4.1"
    ),
    .package(
      url: "https://github.com/open-telemetry/opentelemetry-swift.git",
      from: "2.4.1"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      from: "1.25.0"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-dependencies",
      from: "1.5.1"
    ),
    .package(
      url: "https://github.com/pointfreeco/xctest-dynamic-overlay",
      from: "1.9.0"
    ),
    // swift-sharing 2.9 cross-package traits require a tools-version newer than this package's 6.0.
    .package(
      url: "https://github.com/pointfreeco/swift-sharing",
      exact: "2.8.2"
    ),
  ],
  targets: [
    .target(
      name: "ComposableOTel",
      dependencies: [
        .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "ComposableOTelExporters",
      dependencies: [
        "ComposableOTel",
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        .product(
          name: "OpenTelemetryProtocolExporterHTTP",
          package: "opentelemetry-swift"
        ),
        .product(name: "StdoutExporter", package: "opentelemetry-swift-core"),
      ]
    ),
    .target(
      name: "ComposableOTelTesting",
      dependencies: [
        "ComposableOTel",
        "ComposableOTelExporters",
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        .product(name: "IssueReporting", package: "xctest-dynamic-overlay"),
      ]
    ),
    .testTarget(
      name: "ComposableOTelTests",
      dependencies: [
        "ComposableOTel",
        "ComposableOTelExporters",
        "ComposableOTelTesting",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
      ]
    ),
  ]
)
