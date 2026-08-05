// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "ReleaseDebugRendererFixture",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(name: "swift-composable-otel", path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "ReleaseDebugRendererFixture",
      dependencies: [
        .product(name: "ComposableOTel", package: "swift-composable-otel")
      ]
    )
  ]
)
