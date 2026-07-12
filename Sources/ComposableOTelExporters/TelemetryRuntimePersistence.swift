import Foundation

struct PendingOTLPBatch: Sendable {
  var id: UUID
  var signal: TelemetryRuntimeSignal
  var createdAt: Date
  var attempt: Int
  var request: URLRequest
}

private struct PersistedOTLPBatch: Codable {
  static let currentVersion = 1

  var version: Int
  var id: UUID
  var signal: TelemetryRuntimeSignal
  var createdAt: Date
  var attempt: Int
  var url: URL
  var method: String
  var headers: [String: String]
  var body: Data

  init(_ batch: PendingOTLPBatch) throws {
    guard let url = batch.request.url else {
      throw PersistenceError.missingURL
    }
    version = Self.currentVersion
    id = batch.id
    signal = batch.signal
    createdAt = batch.createdAt
    attempt = batch.attempt
    self.url = url
    method = batch.request.httpMethod ?? "POST"
    headers = (batch.request.allHTTPHeaderFields ?? [:]).filter {
      Self.persistedHeaderNames.contains($0.key.lowercased())
    }
    body = batch.request.httpBody ?? Data()
  }

  func pendingBatch() throws -> PendingOTLPBatch {
    guard version == Self.currentVersion else {
      throw PersistenceError.unsupportedVersion
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    return PendingOTLPBatch(
      id: id,
      signal: signal,
      createdAt: createdAt,
      attempt: attempt,
      request: request
    )
  }

  private static let persistedHeaderNames: Set<String> = [
    "content-encoding",
    "content-type",
    "user-agent",
  ]
}

private enum PersistenceError: Error {
  case missingURL
  case unsupportedVersion
}

struct PersistenceSaveResult {
  var saved: Bool
}

final class RuntimePersistenceStore: @unchecked Sendable {
  private let configuration: TelemetryPersistenceConfiguration
  private let fileSystem: TelemetryRuntimeFileSystem
  private let diagnostics: RuntimeDiagnosticsState
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var stored: [UUID: StoredBatch] = [:]

  private struct StoredBatch {
    var batch: PendingOTLPBatch
    var bytes: Int
    var url: URL
  }

  init(
    configuration: TelemetryPersistenceConfiguration,
    fileSystem: TelemetryRuntimeFileSystem,
    diagnostics: RuntimeDiagnosticsState
  ) throws {
    self.configuration = configuration
    self.fileSystem = fileSystem
    self.diagnostics = diagnostics
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970

    try fileSystem.createDirectory(configuration.directory)
    try fileSystem.applyProtection(configuration.directory, configuration.fileProtection)
    try fileSystem.excludeFromBackup(configuration.directory)
  }

  func load(now: Date) -> [PendingOTLPBatch] {
    let urls: [URL]
    do {
      urls = try fileSystem.listFiles(configuration.directory)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    } catch {
      diagnostics.setPersistence(items: 0, bytes: 0)
      return []
    }

    for url in urls {
      do {
        let data = try fileSystem.read(url)
        let persisted = try decoder.decode(PersistedOTLPBatch.self, from: data)
        let batch = try persisted.pendingBatch()
        guard now.timeIntervalSince(batch.createdAt) <= configuration.maximumAge.runtimeSeconds
        else {
          try? fileSystem.remove(url)
          continue
        }
        stored[batch.id] = StoredBatch(batch: batch, bytes: data.count, url: url)
      } catch {
        try? fileSystem.remove(url)
        diagnostics.recordCorruptionRecovery()
      }
    }

    evictUntilWithinLimit()
    updateDiagnostics()
    return stored.values.map(\.batch).sorted { lhs, rhs in
      if lhs.createdAt == rhs.createdAt {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.createdAt < rhs.createdAt
    }
  }

  func save(_ batch: PendingOTLPBatch) -> PersistenceSaveResult {
    do {
      let persisted = try PersistedOTLPBatch(batch)
      let data = try encoder.encode(persisted)
      let existingBytes = stored[batch.id]?.bytes ?? 0
      guard totalBytes - existingBytes + data.count <= configuration.maximumBytes else {
        return PersistenceSaveResult(saved: false)
      }

      let url = fileURL(for: batch)
      if let existing = stored[batch.id], existing.url != url {
        try? fileSystem.remove(existing.url)
      }
      try fileSystem.writeAtomically(data, url)
      try fileSystem.applyProtection(url, configuration.fileProtection)
      stored[batch.id] = StoredBatch(batch: batch, bytes: data.count, url: url)
      updateDiagnostics()
      return PersistenceSaveResult(saved: true)
    } catch {
      return PersistenceSaveResult(saved: false)
    }
  }

  func remove(_ id: UUID) {
    guard let item = stored.removeValue(forKey: id) else { return }
    try? fileSystem.remove(item.url)
    updateDiagnostics()
  }

  private var totalBytes: Int {
    stored.values.reduce(into: 0) { $0 += $1.bytes }
  }

  private func fileURL(for batch: PendingOTLPBatch) -> URL {
    let milliseconds = Int64(batch.createdAt.timeIntervalSince1970 * 1_000)
    return configuration.directory
      .appendingPathComponent("\(milliseconds)-\(batch.id.uuidString.lowercased()).json")
  }

  private func oldestStored() -> StoredBatch? {
    stored.values.min {
      if $0.batch.createdAt == $1.batch.createdAt {
        return $0.batch.id.uuidString < $1.batch.id.uuidString
      }
      return $0.batch.createdAt < $1.batch.createdAt
    }
  }

  private func evictUntilWithinLimit() {
    while totalBytes > configuration.maximumBytes, let oldest = oldestStored() {
      remove(oldest.batch.id)
      diagnostics.recordDrop(signal: oldest.batch.signal)
    }
  }

  private func updateDiagnostics() {
    diagnostics.setPersistence(items: stored.count, bytes: totalBytes)
  }
}
