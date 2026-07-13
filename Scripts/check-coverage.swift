#!/usr/bin/env swift
import Foundation

struct CoverageFloor {
  let name: String
  let marker: String
  let minimumPercent: Double
  let acceptsFile: (String) -> Bool
}

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("Usage: check-coverage.swift <coverage.json>\n".utf8))
  exit(64)
}

let coverageURL = URL(fileURLWithPath: CommandLine.arguments[1])
let object = try JSONSerialization.jsonObject(with: Data(contentsOf: coverageURL))
guard
  let root = object as? [String: Any],
  let data = root["data"] as? [[String: Any]],
  let first = data.first,
  let files = first["files"] as? [[String: Any]]
else {
  FileHandle.standardError.write(Data("Coverage JSON has an unsupported shape\n".utf8))
  exit(65)
}

let floors = [
  CoverageFloor(
    name: "ComposableOTel",
    marker: "/Sources/ComposableOTel/",
    minimumPercent: 90,
    acceptsFile: { _ in true }
  ),
  CoverageFloor(
    name: "ComposableOTelExporters",
    marker: "/Sources/ComposableOTelExporters/",
    minimumPercent: 80,
    acceptsFile: { _ in true }
  ),
  CoverageFloor(
    name: "ComposableOTelTesting",
    marker: "/Sources/ComposableOTelTesting/",
    minimumPercent: 50,
    acceptsFile: { _ in true }
  ),
  CoverageFloor(
    name: "TelemetryRuntime delivery paths",
    marker: "/Sources/ComposableOTelExporters/",
    minimumPercent: 80,
    acceptsFile: {
      URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("TelemetryRuntime")
    }
  ),
]

var failed = false
for floor in floors {
  var covered = 0
  var count = 0
  for file in files {
    guard
      let filename = file["filename"] as? String,
      filename.contains(floor.marker),
      floor.acceptsFile(filename),
      let summary = file["summary"] as? [String: Any],
      let lines = summary["lines"] as? [String: Any],
      let fileCovered = lines["covered"] as? Int,
      let fileCount = lines["count"] as? Int
    else {
      continue
    }
    covered += fileCovered
    count += fileCount
  }

  guard count > 0 else {
    FileHandle.standardError.write(Data("No coverage data for \(floor.name)\n".utf8))
    failed = true
    continue
  }
  let percent = Double(covered) * 100 / Double(count)
  print(
    String(
      format: "%-32s %6.2f%% (%d/%d), floor %.2f%%",
      (floor.name as NSString).utf8String!,
      percent,
      covered,
      count,
      floor.minimumPercent
    )
  )
  if percent + 0.000_1 < floor.minimumPercent {
    failed = true
  }
}

if failed {
  FileHandle.standardError.write(Data("Coverage floor failed\n".utf8))
  exit(1)
}
