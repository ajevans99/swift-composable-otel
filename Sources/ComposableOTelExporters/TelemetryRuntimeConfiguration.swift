import Foundation

/// A telemetry signal owned by ``TelemetryRuntime``.
public enum TelemetryRuntimeSignal: String, Codable, CaseIterable, Sendable {
  case traces
  case metrics
  case logs
}

/// Standard OTLP/HTTP endpoints for each signal.
public struct OTLPEndpoints: Equatable, Sendable {
  public let traces: URL
  public let metrics: URL
  public let logs: URL

  /// Derives `/v1/traces`, `/v1/metrics`, and `/v1/logs` below a gateway base URL.
  public init(baseURL: URL) {
    traces = baseURL.appendingPathComponent("v1/traces")
    metrics = baseURL.appendingPathComponent("v1/metrics")
    logs = baseURL.appendingPathComponent("v1/logs")
  }

  /// Uses explicit signal endpoints when a gateway does not expose the standard paths.
  public init(traces: URL, metrics: URL, logs: URL) {
    self.traces = traces
    self.metrics = metrics
    self.logs = logs
  }

  func endpoint(for signal: TelemetryRuntimeSignal) -> URL {
    switch signal {
    case .traces:
      traces
    case .metrics:
      metrics
    case .logs:
      logs
    }
  }
}

/// The deterministic policy used when a bounded queue is full.
public enum TelemetryOverflowPolicy: Sendable {
  /// Keep previously accepted telemetry and drop the new item.
  case dropNewest
  /// Drop the oldest queued item and accept the new item.
  case dropOldest
}

/// Span and log batching limits.
public struct TelemetryBatchConfiguration: Sendable {
  public var maximumQueueSize: Int
  public var maximumBatchSize: Int
  public var scheduledDelay: Duration
  public var exportTimeout: Duration
  public var overflowPolicy: TelemetryOverflowPolicy

  public init(
    maximumQueueSize: Int = 2_048,
    maximumBatchSize: Int = 512,
    scheduledDelay: Duration = .seconds(5),
    exportTimeout: Duration = .seconds(10),
    overflowPolicy: TelemetryOverflowPolicy = .dropOldest
  ) {
    self.maximumQueueSize = maximumQueueSize
    self.maximumBatchSize = maximumBatchSize
    self.scheduledDelay = scheduledDelay
    self.exportTimeout = exportTimeout
    self.overflowPolicy = overflowPolicy
  }
}

/// Bounded delivery and retry limits for encoded OTLP requests.
public struct TelemetryDeliveryConfiguration: Sendable {
  public var maximumPendingBatches: Int
  /// Maximum encoded OTLP body accepted into memory or persistence.
  public var maximumEncodedRequestBytes: Int
  public var requestTimeout: Duration
  public var retry: Retry
  public var overflowPolicy: TelemetryOverflowPolicy

  public init(
    maximumPendingBatches: Int = 256,
    maximumEncodedRequestBytes: Int = 64 * 1_024,
    requestTimeout: Duration = .seconds(10),
    retry: Retry = .init(),
    overflowPolicy: TelemetryOverflowPolicy = .dropOldest
  ) {
    self.maximumPendingBatches = maximumPendingBatches
    self.maximumEncodedRequestBytes = maximumEncodedRequestBytes
    self.requestTimeout = requestTimeout
    self.retry = retry
    self.overflowPolicy = overflowPolicy
  }

  public struct Retry: Sendable {
    /// Total attempts, including the initial request.
    public var maximumAttempts: Int
    public var initialBackoff: Duration
    public var maximumBackoff: Duration
    /// A value from zero through one applied symmetrically to each backoff.
    public var jitterRatio: Double

    public init(
      maximumAttempts: Int = 4,
      initialBackoff: Duration = .seconds(1),
      maximumBackoff: Duration = .seconds(30),
      jitterRatio: Double = 0.2
    ) {
      self.maximumAttempts = maximumAttempts
      self.initialBackoff = initialBackoff
      self.maximumBackoff = maximumBackoff
      self.jitterRatio = jitterRatio
    }
  }
}

/// Optional bounded disk persistence for sanitized, encoded OTLP requests.
public struct TelemetryPersistenceConfiguration: Sendable {
  public enum FileProtection: Sendable {
    /// Allows background delivery after the device has been unlocked once since boot.
    case completeUntilFirstUserAuthentication
    /// Requires the device to be unlocked whenever a spool file is accessed.
    case complete
  }

  public var directory: URL
  public var maximumBytes: Int
  public var maximumAge: Duration
  public var fileProtection: FileProtection

  public init(
    directory: URL,
    maximumBytes: Int = 5 * 1_024 * 1_024,
    maximumAge: Duration = .seconds(24 * 60 * 60),
    fileProtection: FileProtection = .completeUntilFirstUserAuthentication
  ) {
    self.directory = directory
    self.maximumBytes = maximumBytes
    self.maximumAge = maximumAge
    self.fileProtection = fileProtection
  }
}

/// A response returned by a host-supplied telemetry transport.
public struct TelemetryHTTPResponse: Equatable, Sendable {
  public let statusCode: Int
  /// A host-parsed numeric `Retry-After` delay. HTTP-date values are intentionally unsupported.
  public let retryAfter: Duration?

  public init(statusCode: Int, retryAfter: Duration? = nil) {
    self.statusCode = statusCode
    self.retryAfter = retryAfter
  }
}

/// Sends an already-authorized OTLP request.
///
/// The runtime invokes this closure away from the main actor and enforces its own timeout. The
/// implementation should still observe task cancellation and cancel its underlying network request.
/// A custom transport may invalidate host credentials when it observes HTTP 401 before returning
/// that non-retryable response; the authenticator will run again for a later independent request.
public struct TelemetryHTTPTransport: Sendable {
  private let operation: @Sendable (URLRequest) async throws -> TelemetryHTTPResponse

  public init(
    send: @escaping @Sendable (URLRequest) async throws -> TelemetryHTTPResponse
  ) {
    operation = send
  }

  public func send(_ request: URLRequest) async throws -> TelemetryHTTPResponse {
    try await operation(request)
  }

  /// An ephemeral URLSession transport with caching and cookie storage disabled.
  public static func urlSession(_ session: URLSession? = nil) -> Self {
    let resolvedSession: URLSession
    if let session {
      resolvedSession = session
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      configuration.httpCookieStorage = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      resolvedSession = URLSession(configuration: configuration)
    }
    return Self { request in
      let (_, response) = try await resolvedSession.data(for: request)
      guard let response = response as? HTTPURLResponse else {
        throw TelemetryRuntimeTransportError.invalidResponse
      }
      return TelemetryHTTPResponse(
        statusCode: response.statusCode,
        retryAfter: retryAfter(from: response)
      )
    }
  }

  private static func retryAfter(from response: HTTPURLResponse) -> Duration? {
    numericRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
  }

  static func numericRetryAfter(_ value: String?) -> Duration? {
    guard
      let value,
      let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)),
      seconds.isFinite,
      seconds >= 0
    else {
      return nil
    }
    return .runtimeSeconds(min(seconds, TimeInterval(Int32.max)))
  }
}

/// Adds fresh, short-lived authorization material immediately before every network attempt.
///
/// Authorization is never persisted. The closure may fetch or refresh an expiring token and should
/// not capture a static vendor secret from an application bundle.
public struct TelemetryRequestAuthenticator: Sendable {
  private let operation: @Sendable (URLRequest) async throws -> URLRequest

  public init(
    authorize: @escaping @Sendable (URLRequest) async throws -> URLRequest
  ) {
    operation = authorize
  }

  public func authorize(_ request: URLRequest) async throws -> URLRequest {
    try await operation(request)
  }

  /// No request mutation, for gateways that authenticate by another host-managed mechanism.
  public static let none = Self { $0 }
}

public enum TelemetryRuntimeTransportError: Error, Equatable, Sendable {
  case invalidResponse
}

/// A reachability or policy hint. It controls scheduling but never predicts request success.
public enum TelemetryExportCondition: Sendable {
  case available
  case constrained
  case unavailable
}

/// Configuration rejected before a production runtime is created.
public enum TelemetryRuntimeConfigurationError: Error, Equatable, Sendable {
  case endpointMustUseTLS(signal: TelemetryRuntimeSignal)
  case endpointMissingHost(signal: TelemetryRuntimeSignal)
  case endpointContainsCredentials(signal: TelemetryRuntimeSignal)
  case endpointContainsQueryOrFragment(signal: TelemetryRuntimeSignal)
  case invalidSamplingRatio
  case invalidBatchLimits
  case invalidDeliveryLimits
  case invalidPersistenceLimits
  case invalidResourceContract
}

extension TelemetryRuntimeConfigurationError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .endpointMustUseTLS(let signal):
      "The \(signal.rawValue) OTLP endpoint must use HTTPS."
    case .endpointMissingHost(let signal):
      "The \(signal.rawValue) OTLP endpoint must include a host."
    case .endpointContainsCredentials(let signal):
      "The \(signal.rawValue) OTLP endpoint must not contain embedded credentials."
    case .endpointContainsQueryOrFragment(let signal):
      "The \(signal.rawValue) OTLP endpoint must not contain a query or fragment."
    case .invalidSamplingRatio:
      "The trace sampling ratio must be finite and between zero and one."
    case .invalidBatchLimits:
      "Batch limits must be positive and the batch size cannot exceed the queue size."
    case .invalidDeliveryLimits:
      "Delivery, timeout, retry, backoff, and jitter limits are invalid."
    case .invalidPersistenceLimits:
      "Persistence size and age limits must be positive and use a file URL."
    case .invalidResourceContract:
      "The immutable resource value must match a registered catalog definition."
    }
  }
}

extension Duration {
  var runtimeSeconds: TimeInterval {
    let components = self.components
    return TimeInterval(components.seconds)
      + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
  }
}
