import OpenTelemetrySdk

/// Controls whether sanitized metric points may retain bounded trace links.
///
/// Exemplar attributes are always removed. Enabled policies retain only exemplars with valid SDK
/// trace and span identifiers, and never change metric attributes or series cardinality.
public enum TelemetryMetricExemplarPolicy: Equatable, Sendable {
  /// Removes every exemplar. This is the default.
  case disabled
  /// Retains valid trace context for at most the selected finite number of exemplars per data point.
  case traceContext(maximumPerDataPoint: MaximumPerDataPoint)

  /// The finite per-data-point exemplar ceiling.
  public enum MaximumPerDataPoint: Int, CaseIterable, Sendable {
    case one = 1
    case two = 2
  }

  package var maximumPerDataPoint: Int {
    switch self {
    case .disabled:
      0
    case .traceContext(let maximum):
      maximum.rawValue
    }
  }

  package var sdkFilter: any ExemplarFilter {
    switch self {
    case .disabled:
      AlwaysOffFilter()
    case .traceContext:
      TraceBasedFilter()
    }
  }
}
