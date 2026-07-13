#!/usr/bin/env swift
import Foundation

struct APISymbol: Codable, Comparable {
  let module: String
  let preciseIdentifier: String
  let kind: String
  let path: String
  let declaration: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.key < rhs.key
  }

  var key: String {
    "\(module)|\(preciseIdentifier)"
  }
}

func normalizedDeclaration(_ declaration: String, path: String) -> String {
  var result = declaration.replacingOccurrences(of: "any ", with: "")
  for qualification in [
    "Self.",
    "TelemetryBootstrap.",
    "TelemetryDeliveryConfiguration.",
    "TelemetryPersistenceConfiguration.",
    "TelemetryRuntime.",
    "TelemetryRuntimeDiagnosticEvent.",
    "TelemetryRuntimeOperationResult.",
    "TelemetrySchema.",
    "TelemetrySignalOperationResult.",
  ] {
    result = result.replacingOccurrences(of: qualification, with: "")
  }
  if path.hasSuffix(".other"), result.hasPrefix("static var other:") {
    return "static var other: Self { get }"
  }
  return result
}

func argument(after name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name) else { return nil }
  let valueIndex = CommandLine.arguments.index(after: index)
  guard valueIndex < CommandLine.arguments.endIndex else { return nil }
  return CommandLine.arguments[valueIndex]
}

guard
  let graphDirectory = argument(after: "--symbol-graphs"),
  let baselinePath = argument(after: "--baseline")
else {
  FileHandle.standardError.write(
    Data(
      "Usage: check-api.swift --symbol-graphs <directory> --baseline <file> [--update]\n".utf8
    )
  )
  exit(64)
}

let packageModules = Set(["ComposableOTel", "ComposableOTelExporters", "ComposableOTelTesting"])
let graphURL = URL(fileURLWithPath: graphDirectory)
let graphFiles = try FileManager.default.contentsOfDirectory(
  at: graphURL,
  includingPropertiesForKeys: nil
).filter {
  $0.pathExtension == "json" && $0.lastPathComponent.contains(".symbols.")
}

var current: [APISymbol] = []
for file in graphFiles {
  let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
  guard
    let root = object as? [String: Any],
    let module = root["module"] as? [String: Any],
    let moduleName = module["name"] as? String,
    packageModules.contains(moduleName),
    let symbols = root["symbols"] as? [[String: Any]]
  else {
    continue
  }

  for symbol in symbols {
    guard
      let accessLevel = symbol["accessLevel"] as? String,
      accessLevel == "public" || accessLevel == "open",
      let identifier = symbol["identifier"] as? [String: Any],
      let precise = identifier["precise"] as? String,
      let kindObject = symbol["kind"] as? [String: Any],
      let kind = kindObject["identifier"] as? String,
      kind != "swift.extension",
      let pathComponents = symbol["pathComponents"] as? [String],
      let fragments = symbol["declarationFragments"] as? [[String: Any]]
    else {
      continue
    }
    let path = pathComponents.joined(separator: ".")
    let declaration = normalizedDeclaration(
      fragments.compactMap { $0["spelling"] as? String }.joined(),
      path: path
    )
    current.append(
      APISymbol(
        module: moduleName,
        preciseIdentifier: precise,
        kind: kind,
        path: path,
        declaration: declaration
      )
    )
  }
}

current.sort()
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let baselineURL = URL(fileURLWithPath: baselinePath)

if CommandLine.arguments.contains("--update") {
  let data = try encoder.encode(current)
  try data.write(to: baselineURL, options: .atomic)
  print("Updated \(baselinePath) with \(current.count) public symbols")
  exit(0)
}

let baseline = try JSONDecoder().decode(
  [APISymbol].self,
  from: Data(contentsOf: baselineURL)
)
let baselineByKey = Dictionary(uniqueKeysWithValues: baseline.map { ($0.key, $0) })
let currentByKey = Dictionary(uniqueKeysWithValues: current.map { ($0.key, $0) })
let removed = baseline.filter { currentByKey[$0.key] == nil }
let changed = baseline.compactMap { previous -> (APISymbol, APISymbol)? in
  guard let now = currentByKey[previous.key], now != previous else { return nil }
  return (previous, now)
}
let added = current.filter { baselineByKey[$0.key] == nil }

for symbol in removed {
  print("BREAKING removed: [\(symbol.module)] \(symbol.declaration)")
}
for (previous, now) in changed {
  print("BREAKING changed: [\(previous.module)] \(previous.declaration)")
  print("                 -> \(now.declaration)")
}
for symbol in added {
  print("ADDED: [\(symbol.module)] \(symbol.declaration)")
}
print(
  "Public API: \(current.count) symbols, \(removed.count) removed, "
    + "\(changed.count) changed, \(added.count) added"
)

if !removed.isEmpty || !changed.isEmpty {
  exit(1)
}
