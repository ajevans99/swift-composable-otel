import Foundation
import OpenTelemetryApi

/// An anonymous identifier that is stable only for the lifetime of the current process.
///
/// The package generates ``current`` once per process. Hosts may supply a deterministic value in
/// tests, but should never derive this identifier from an account, device, installation, or other
/// persistent identity.
public struct TelemetryProcessSessionID: Equatable, Hashable, Sendable {
  /// The anonymous identifier shared by telemetry clients created in this process.
  public static let current = Self(UUID())

  /// The underlying anonymous UUID.
  public let rawValue: UUID

  public init(_ rawValue: UUID) {
    self.rawValue = rawValue
  }

  /// Creates an identifier only from a canonical lowercase UUID string.
  public init?(validating value: String) {
    guard
      let identifier = UUID(uuidString: value),
      identifier.uuidString.lowercased() == value
    else {
      return nil
    }
    self.init(identifier)
  }

  package var canonicalValue: String {
    rawValue.uuidString.lowercased()
  }
}

/// The finite Apple platform surface allowed in registered host context.
public enum TelemetryHostPlatform: String, CaseIterable, Sendable {
  /// iOS, including Mac Catalyst.
  case iOS = "ios"
  /// macOS.
  case macOS = "macos"
  /// watchOS.
  case watchOS = "watchos"

  /// The platform on which this package is currently executing.
  public static var current: Self {
    #if os(iOS)
      .iOS
    #elseif os(watchOS)
      .watchOS
    #else
      .macOS
    #endif
  }
}

/// The finite process role allowed in registered host context.
public enum TelemetryHostProcessKind: String, CaseIterable, Sendable {
  /// A host application's primary process.
  case application
  /// An application extension process.
  case appExtension = "app-extension"
  /// A test process.
  case test
}

/// A deliberately small, typed context attached only to sanitized spans and logs.
///
/// The process-session identifier is anonymous and non-persistent. Platform and process kind are
/// finite enums rather than host-provided strings. This context is never passed to metric
/// instruments or metric attribute builders.
public struct TelemetryHostContext: Equatable, Sendable {
  /// The anonymous process-lifetime session identifier.
  public let processSessionID: TelemetryProcessSessionID
  /// The finite host platform.
  public let platform: TelemetryHostPlatform
  /// The finite process role.
  public let processKind: TelemetryHostProcessKind

  public init(
    processSessionID: TelemetryProcessSessionID = .current,
    platform: TelemetryHostPlatform = .current,
    processKind: TelemetryHostProcessKind = .application
  ) {
    self.processSessionID = processSessionID
    self.platform = platform
    self.processKind = processKind
  }

  package var sanitizedAttributes: [String: AttributeValue]? {
    let session = processSessionID.canonicalValue
    guard
      TelemetryProcessSessionID(validating: session) == processSessionID,
      TelemetryHostPlatform(rawValue: platform.rawValue) == platform,
      TelemetryHostProcessKind(rawValue: processKind.rawValue) == processKind
    else {
      return nil
    }
    return [
      TCAAttributes.processSessionID: .string(session),
      TCAAttributes.hostPlatform: .string(platform.rawValue),
      TCAAttributes.hostProcessKind: .string(processKind.rawValue),
    ]
  }
}
