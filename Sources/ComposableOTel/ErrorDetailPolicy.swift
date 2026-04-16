/// Controls how error details are exported in telemetry.
public enum ErrorDetailPolicy: Sendable {
  /// Emit only generic log body and error type. Default.
  case redacted
  /// Emit a host-supplied sanitized error summary.
  case safeSummary(@Sendable (any Error) -> String)
  /// Emit full error descriptions. Only for trusted environments.
  case full
}

extension ErrorDetailPolicy {
  public func errorBody(for error: any Error, context: String) -> String {
    switch self {
    case .redacted:
      return context
    case .safeSummary(let summarize):
      return summarize(error)
    case .full:
      return String(describing: error)
    }
  }

  public var isRedacted: Bool {
    if case .redacted = self { return true }
    return false
  }
}
