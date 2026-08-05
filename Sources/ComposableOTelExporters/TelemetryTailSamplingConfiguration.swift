import Foundation

/// Configuration for client-side promotion of traces missed by head sampling.
public enum TelemetryTailSamplingConfiguration: Sendable {
  /// Uses ordinary SDK head sampling without retaining missed traces.
  case disabled
  /// Records missed traces into a bounded, sanitized, memory-only buffer.
  case enabled(TelemetryTailSamplingPolicy)

  package var policy: TelemetryTailSamplingPolicy? {
    guard case .enabled(let policy) = self else { return nil }
    return policy
  }
}

/// Validated count, byte-estimate, age, and latency bounds for tail promotion.
public struct TelemetryTailSamplingPolicy: Equatable, Sendable {
  /// Hard upper bound accepted for retained trace entries.
  public static let maximumAllowedTraceCount = 256
  /// Hard upper bound accepted for retained spans.
  public static let maximumAllowedSpanCount = 1_024
  /// Hard upper bound accepted for retained log breadcrumbs.
  public static let maximumAllowedBreadcrumbCount = 1_024
  /// Hard upper bound accepted for the total encoded-byte estimate.
  public static let maximumAllowedRetainedBytes = 16 * 1_024 * 1_024
  /// Hard upper bound accepted for memory-only retention.
  public static let maximumAllowedAge: Duration = .seconds(5 * 60)

  /// A reviewed duration that promotes a span's complete retained trace.
  public let slowTraceThreshold: Duration
  /// Maximum simultaneous trace entries.
  public let maximumTraceCount: Int
  /// Maximum sanitized spans retained across all trace entries.
  public let maximumRetainedSpanCount: Int
  /// Maximum sanitized log breadcrumbs retained across all trace entries.
  public let maximumRetainedBreadcrumbCount: Int
  /// Maximum deterministic encoded-byte estimate retained in memory.
  public let maximumRetainedBytes: Int
  /// Maximum age of any unpromoted trace entry.
  public let maximumAge: Duration

  /// Creates a bounded policy with an explicitly reviewed slow-span threshold.
  public init(
    slowTraceThreshold: Duration,
    maximumTraceCount: Int = 32,
    maximumRetainedSpanCount: Int = 256,
    maximumRetainedBreadcrumbCount: Int = 128,
    maximumRetainedBytes: Int = 512 * 1_024,
    maximumAge: Duration = .seconds(30)
  ) throws {
    guard
      (1...Self.maximumAllowedTraceCount).contains(maximumTraceCount),
      (1...Self.maximumAllowedSpanCount).contains(maximumRetainedSpanCount),
      (1...Self.maximumAllowedBreadcrumbCount).contains(maximumRetainedBreadcrumbCount),
      (1...Self.maximumAllowedRetainedBytes).contains(maximumRetainedBytes),
      maximumAge > .zero,
      maximumAge <= Self.maximumAllowedAge,
      slowTraceThreshold > .zero,
      slowTraceThreshold <= maximumAge
    else {
      throw TelemetryTailSamplingConfigurationError.invalidLimits
    }
    self.slowTraceThreshold = slowTraceThreshold
    self.maximumTraceCount = maximumTraceCount
    self.maximumRetainedSpanCount = maximumRetainedSpanCount
    self.maximumRetainedBreadcrumbCount = maximumRetainedBreadcrumbCount
    self.maximumRetainedBytes = maximumRetainedBytes
    self.maximumAge = maximumAge
  }
}

/// A tail policy was rejected without echoing configured values.
public enum TelemetryTailSamplingConfigurationError: Error, Equatable, Sendable {
  /// One or more count, byte, age, or latency limits are invalid.
  case invalidLimits
}
