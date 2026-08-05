import OpenTelemetryApi

/// A validated deterministic sampling rate for one log severity.
public struct TelemetryLogSamplingRate: Equatable, Hashable, Sendable {
  /// Records every eligible log.
  public static let always = Self(validated: 1)
  /// Records no eligible logs.
  public static let never = Self(validated: 0)

  /// The finite rate from zero through one.
  public let rawValue: Double

  /// Creates a finite rate from zero through one.
  public init?(_ rawValue: Double) {
    guard rawValue.isFinite, (0...1).contains(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  private init(validated rawValue: Double) {
    self.rawValue = rawValue
  }
}

/// Severity filtering and deterministic per-severity sampling for privacy-aware logs.
///
/// Defaults retain both supported severities when logs are enabled. Logs remain disabled by default
/// through ``TelemetrySignalConfiguration``.
public struct TelemetryLoggingConfiguration: Equatable, Sendable {
  /// The least severe eligible log level.
  public var minimumSeverity: TelemetryLogSeverity
  /// The deterministic sampling rate for informational logs.
  public var infoSampling: TelemetryLogSamplingRate
  /// The deterministic sampling rate for error logs.
  public var errorSampling: TelemetryLogSamplingRate
  /// A stable, non-secret seed used by the deterministic sampler.
  public var deterministicSeed: UInt64

  public init(
    minimumSeverity: TelemetryLogSeverity = .info,
    infoSampling: TelemetryLogSamplingRate = .always,
    errorSampling: TelemetryLogSamplingRate = .always,
    deterministicSeed: UInt64 = 0x6f74_656c_2d6c_6f67
  ) {
    self.minimumSeverity = minimumSeverity
    self.infoSampling = infoSampling
    self.errorSampling = errorSampling
    self.deterministicSeed = deterministicSeed
  }
}

extension TelemetryLogSeverity {
  package init?(otelSeverity: Severity?) {
    switch otelSeverity {
    case .info:
      self = .info
    case .error:
      self = .error
    default:
      return nil
    }
  }

  fileprivate var rank: Int {
    switch self {
    case .info: 0
    case .error: 1
    }
  }
}

extension TelemetryLoggingConfiguration {
  package func shouldRecord(
    severity: TelemetryLogSeverity,
    stableIdentifier: String
  ) -> Bool {
    guard severity.rank >= minimumSeverity.rank else { return false }
    let rate =
      switch severity {
      case .info: infoSampling.rawValue
      case .error: errorSampling.rawValue
      }
    guard rate > 0 else { return false }
    guard rate < 1 else { return true }

    var hash = deterministicSeed ^ 14_695_981_039_346_656_037
    for byte in severity.rawValue.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    hash ^= 0xff
    hash &*= 1_099_511_628_211
    for byte in stableIdentifier.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return Double(hash) / Double(UInt64.max) < rate
  }
}
