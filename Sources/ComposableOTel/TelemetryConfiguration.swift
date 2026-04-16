import Foundation

/// Global configuration for ComposableOTel.
public final class TelemetryConfiguration: @unchecked Sendable {
  public static let shared = TelemetryConfiguration()

  private let lock = NSLock()
  private var _errorDetailPolicy: ErrorDetailPolicy = .redacted
  private var _redactor: any SpanAttributeRedactor = NoOpRedactor()

  public var errorDetailPolicy: ErrorDetailPolicy {
    get { lock.lock(); defer { lock.unlock() }; return _errorDetailPolicy }
    set { lock.lock(); defer { lock.unlock() }; _errorDetailPolicy = newValue }
  }

  public var redactor: any SpanAttributeRedactor {
    get { lock.lock(); defer { lock.unlock() }; return _redactor }
    set { lock.lock(); defer { lock.unlock() }; _redactor = newValue }
  }
}
