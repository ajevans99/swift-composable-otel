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
      from: "2.3.0"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      from: "1.17.0"
    ),
    .package(
      url: "https://github.com/pointfreeco/swift-dependencies",
      from: "1.4.0"
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
        .product(name: "StdoutExporter", package: "opentelemetry-swift-core"),
      ]
    ),
    .target(
      name: "ComposableOTelTesting",
      dependencies: [
        "ComposableOTel",
        .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
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
