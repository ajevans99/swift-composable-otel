// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "UnsafeAPIFixture",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "swift-composable-otel", path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "UnsafeAPIFixture",
      dependencies: [
        .product(name: "ComposableOTel", package: "swift-composable-otel"),
        .product(name: "ComposableOTelExporters", package: "swift-composable-otel"),
      ]
    )
  ]
)
