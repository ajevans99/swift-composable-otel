import Foundation
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

/// A process-wide monotonically increasing per-record identity used only for sampling.
package final class TelemetryLogRecordSequence: @unchecked Sendable {
  package static let shared = TelemetryLogRecordSequence()

  private let lock = NSLock()
  private var value: UInt64 = 0

  package func next() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    value &+= 1
    return value
  }
}

extension TelemetryLoggingConfiguration {
  /// Samples one log record independently of every other record.
  ///
  /// The decision is keyed by the anonymous process session plus the record's own identity: its
  /// stable event name, its span ID when correlated, and a per-process sequence number. A
  /// fractional rate therefore retains a proportional share of every event name rather than
  /// retaining or dropping whole event names. It is evaluated exactly once, at emission; export
  /// boundaries apply only the severity filter.
  package func shouldRecord(
    severity: TelemetryLogSeverity,
    processSessionID: TelemetryProcessSessionID,
    eventName: String,
    spanID: String?,
    sequence: UInt64
  ) -> Bool {
    guard passesSeverityFilter(severity) else { return false }
    let rate =
      switch severity {
      case .info: infoSampling.rawValue
      case .error: errorSampling.rawValue
      }
    guard rate > 0 else { return false }
    guard rate < 1 else { return true }

    var hash = deterministicSeed ^ 14_695_981_039_346_656_037
    for component in [
      severity.rawValue,
      processSessionID.rawValue.uuidString,
      eventName,
      spanID ?? "",
      String(sequence),
    ] {
      for byte in component.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      hash ^= 0xff
      hash &*= 1_099_511_628_211
    }
    hash ^= hash >> 33
    hash &*= 0xff51_afd7_ed55_8ccd
    hash ^= hash >> 33
    return Double(hash) / Double(UInt64.max) < rate
  }

  package func passesSeverityFilter(_ severity: TelemetryLogSeverity) -> Bool {
    severity.rank >= minimumSeverity.rank
  }
}
