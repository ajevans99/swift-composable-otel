import Foundation

let fileManager = FileManager.default
let repositoryRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let sourceRoot = repositoryRoot.appendingPathComponent("Sources")
var failures: [String] = []

func read(_ relativePath: String) -> String {
  let url = repositoryRoot.appendingPathComponent(relativePath)
  do {
    return try String(contentsOf: url, encoding: .utf8)
  } catch {
    failures.append("Unable to read \(relativePath): \(error)")
    return ""
  }
}

func markdownFiles(in root: URL) -> [URL] {
  guard
    let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey]
    )
  else {
    failures.append("Unable to enumerate \(root.path)")
    return []
  }

  return enumerator.compactMap { entry in
    guard let url = entry as? URL, url.pathExtension == "md" else { return nil }
    return url
  }
}

let rootMarkdown =
  (try? fileManager.contentsOfDirectory(
    at: repositoryRoot,
    includingPropertiesForKeys: [.isRegularFileKey]
  ))?.filter { $0.pathExtension == "md" } ?? []
let documentationMarkdown = markdownFiles(in: sourceRoot)
let allMarkdown = rootMarkdown + documentationMarkdown
let markdownLinkExpression = try NSRegularExpression(
  pattern: #"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#
)
let docLinkExpression = try NSRegularExpression(pattern: #"<doc:([^>]+)>"#)
let articleNames = Set(
  documentationMarkdown
    .filter { $0.path.contains("/Articles/") }
    .map { $0.deletingPathExtension().lastPathComponent }
)

for fileURL in allMarkdown {
  let contents: String
  do {
    contents = try String(contentsOf: fileURL, encoding: .utf8)
  } catch {
    failures.append("Unable to read \(fileURL.path): \(error)")
    continue
  }

  let fullRange = NSRange(contents.startIndex..., in: contents)
  for match in markdownLinkExpression.matches(in: contents, range: fullRange) {
    guard
      let targetRange = Range(match.range(at: 1), in: contents)
    else { continue }

    let target = String(contents[targetRange])
    if target.hasPrefix("http://") || target.hasPrefix("https://")
      || target.hasPrefix("mailto:") || target.hasPrefix("#")
    {
      continue
    }

    let path = String(target.split(separator: "#", maxSplits: 1)[0])
    let decodedPath = path.removingPercentEncoding ?? path
    let destination = fileURL.deletingLastPathComponent()
      .appendingPathComponent(decodedPath)
      .standardizedFileURL
    if !fileManager.fileExists(atPath: destination.path) {
      let relativeFile = fileURL.path.replacingOccurrences(
        of: repositoryRoot.path + "/",
        with: ""
      )
      failures.append("\(relativeFile) links to missing path \(target)")
    }
  }

  for match in docLinkExpression.matches(in: contents, range: fullRange) {
    guard let targetRange = Range(match.range(at: 1), in: contents) else { continue }
    let target = String(contents[targetRange])
    if !articleNames.contains(target) {
      failures.append("\(fileURL.lastPathComponent) links to missing DocC article \(target)")
    }
  }
}

for requiredFile in [
  "CHANGELOG.md",
  "LICENSE",
  "MIGRATION.md",
  "PERFORMANCE.md",
  "PILOT.md",
  "PRIVACY.md",
  "README.md",
  "RELEASE_NOTES.md",
  "RELEASING.md",
  "SECURITY.md",
  "SUPPORT.md",
] {
  if !fileManager.fileExists(atPath: repositoryRoot.appendingPathComponent(requiredFile).path) {
    failures.append("Missing required project document \(requiredFile)")
  }
}

let license = read("LICENSE")
let expectedLicenseHeader = """
  MIT License

  Copyright (c) 2026 ajevans99
  """
if !license.hasPrefix(expectedLicenseHeader) {
  failures.append("LICENSE must contain the approved MIT identifier and copyright line")
}
for requiredClause in [
  "Permission is hereby granted, free of charge, to any person obtaining a copy",
  "The above copyright notice and this permission notice shall be included in all",
  "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR",
] where !license.contains(requiredClause) {
  failures.append("LICENSE is missing standard MIT text: \(requiredClause)")
}

let metadata = read("Sources/ComposableOTel/ComposableOTelMetadata.swift")
let versionExpression = try NSRegularExpression(
  pattern: #"public static let version = \"([0-9]+\.[0-9]+\.[0-9]+)\""#
)
let metadataRange = NSRange(metadata.startIndex..., in: metadata)
let versionMatch = versionExpression.firstMatch(in: metadata, range: metadataRange)
let packageVersion: String?
if let versionMatch, let range = Range(versionMatch.range(at: 1), in: metadata) {
  packageVersion = String(metadata[range])
} else {
  failures.append("ComposableOTelMetadata.version is missing or is not semantic version syntax")
  packageVersion = nil
}

let readme = read("README.md")
if !readme.contains("[MIT License](LICENSE), SPDX identifier `MIT`") {
  failures.append("README must reference the approved MIT license and SPDX identifier")
}
if let packageVersion {
  let expectedInstallation =
    #".package("# + "\n"
    + #"    url: "https://github.com/ajevans99/swift-composable-otel.git","# + "\n"
    + #"    from: "\#(packageVersion)""#
  if !readme.contains(expectedInstallation) {
    failures.append("README installation does not use ComposableOTelMetadata.version")
  }
}

let forbiddenDocumentation = [
  "github.com/your-org/swift-composable-otel",
  "TelemetryClient.test(spanCollector:",
  "TelemetryClient.test(metricReader:errorDetailPolicy:)",
  "configureTestTelemetry",
  "SpanAttributeRedactor",
  "ErrorDetailPolicy",
  "stateDiffs",
  "tracedRun(name:",
  "traceStart(name:",
  #"tracedCall(""#,
  #"named: "reducer/"#,
  #"named: "effect/"#,
  #"named: "dependency/"#,
  "tca.action.type",
  "tca.reducer.name",
  "as! TracerProviderSdk",
]
for forbidden in forbiddenDocumentation
where ([repositoryRoot.appendingPathComponent("README.md")] + documentationMarkdown).contains(
  where: {
    (try? String(contentsOf: $0, encoding: .utf8).contains(forbidden)) == true
  })
{
  failures.append("Documentation contains stale example text: \(forbidden)")
}

for requiredPrivacyClaim in [
  "logs are disabled by default",
  "deterministically aggregate to",
  "PrivacyPreservingSpanExporter",
  "unsafeCustomSDK",
  "watchOS | Unsupported",
  "best-effort",
  "short-lived",
  "`TelemetryRuntime`",
  "never persisted",
] where !readme.contains(requiredPrivacyClaim) {
  failures.append("README is missing required privacy/support claim: \(requiredPrivacyClaim)")
}

let manifest = read("Package.swift")
if !manifest.contains(".iOS(.v17)") || !manifest.contains(".macOS(.v14)") {
  failures.append("Package.swift must retain the documented iOS 17 and macOS 14 minimums")
}
if manifest.contains(".watchOS(") {
  failures.append("Do not declare watchOS until the documented watchOS support gate passes")
}
if !manifest.contains("open-telemetry/opentelemetry-swift.git")
  || !manifest.contains("OpenTelemetryProtocolExporterHTTP")
{
  failures.append("Package.swift must include the official OTLP/HTTP exporter product")
}

let bootstrap = read("Sources/ComposableOTelExporters/TelemetryBootstrap.swift")
if bootstrap.contains("case production") || bootstrap.contains("StdoutSpanExporter(isDebug: false)")
{
  failures.append("Production stdout must remain impossible through TelemetryBootstrap")
}

let runtime = read("Sources/ComposableOTelExporters/TelemetryRuntime.swift")
for requiredRuntimeBoundary in [
  "OtlpHttpTraceExporter",
  "OtlpHttpMetricExporter",
  "OtlpHttpLogExporter",
  "deploymentEnvironment: \"production\"",
] where !runtime.contains(requiredRuntimeBoundary) {
  failures.append("TelemetryRuntime is missing production boundary: \(requiredRuntimeBoundary)")
}
if runtime.contains("Stdout") {
  failures.append("TelemetryRuntime must not reference stdout exporters")
}

if failures.isEmpty {
  print("Documentation and package baseline validation passed")
} else {
  for failure in failures {
    FileHandle.standardError.write(Data("error: \(failure)\n".utf8))
  }
  exit(1)
}
