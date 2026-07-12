import Foundation

struct TelemetryRuntimeClock: Sendable {
  var now: @Sendable () -> Date
  var sleep: @Sendable (Duration) async throws -> Void
  var randomUnit: @Sendable () -> Double

  static let live = Self(
    now: Date.init,
    sleep: { duration in
      try await Task.sleep(for: duration)
    },
    randomUnit: {
      Double.random(in: 0...1)
    }
  )
}

struct TelemetryRuntimeFileSystem: Sendable {
  var createDirectory: @Sendable (URL) throws -> Void
  var listFiles: @Sendable (URL) throws -> [URL]
  var read: @Sendable (URL) throws -> Data
  var writeAtomically: @Sendable (Data, URL) throws -> Void
  var remove: @Sendable (URL) throws -> Void
  var applyProtection:
    @Sendable (URL, TelemetryPersistenceConfiguration.FileProtection) throws ->
      Void
  var excludeFromBackup: @Sendable (URL) throws -> Void

  static let live = Self(
    createDirectory: { url in
      try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
      )
    },
    listFiles: { url in
      try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
      )
    },
    read: { url in
      try Data(contentsOf: url)
    },
    writeAtomically: { data, url in
      try data.write(to: url, options: .atomic)
    },
    remove: { url in
      try FileManager.default.removeItem(at: url)
    },
    applyProtection: { url, protection in
      let value: FileProtectionType =
        switch protection {
        case .completeUntilFirstUserAuthentication:
          .completeUntilFirstUserAuthentication
        case .complete:
          .complete
        }
      try FileManager.default.setAttributes(
        [.protectionKey: value],
        ofItemAtPath: url.path
      )
    },
    excludeFromBackup: { originalURL in
      var url = originalURL
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
    }
  )
}

struct TelemetryRuntimeDependencies: Sendable {
  var clock: TelemetryRuntimeClock
  var fileSystem: TelemetryRuntimeFileSystem
  var makeID: @Sendable () -> UUID

  static let live = Self(
    clock: .live,
    fileSystem: .live,
    makeID: UUID.init
  )
}

extension Duration {
  static func runtimeSeconds(_ value: TimeInterval) -> Duration {
    .milliseconds(Int64((value * 1_000).rounded()))
  }
}
