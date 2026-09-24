import OpenTelemetryApi

enum ReducerTraceContext {
  @TaskLocal static var spanContext: SpanContext?
  @TaskLocal static var instrumentationSuppressed = false
  /// The schema-bounded feature that originated the current reducer, effect, or root flow.
  @TaskLocal static var feature: FeatureID?

  struct Capture: Sendable {
    let spanContext: SpanContext?
    let instrumentationSuppressed: Bool
    let feature: FeatureID?

    func withValues<Value>(
      _ operation: () async throws -> Value
    ) async rethrows -> Value {
      try await ReducerTraceContext.$instrumentationSuppressed.withValue(
        instrumentationSuppressed
      ) {
        try await ReducerTraceContext.$feature.withValue(feature) {
          try await ReducerTraceContext.$spanContext.withValue(spanContext) {
            try await operation()
          }
        }
      }
    }
  }

  static func capture() -> Capture {
    Capture(
      spanContext: spanContext,
      instrumentationSuppressed: instrumentationSuppressed,
      feature: feature
    )
  }

  /// Adds the propagated feature name to span and log attributes.
  static func addingFeature(
    to attributes: [String: AttributeValue],
    feature: FeatureID? = ReducerTraceContext.feature
  ) -> [String: AttributeValue] {
    guard let feature else { return attributes }
    var attributes = attributes
    attributes[TCAAttributes.featureName] = .string(feature.rawValue)
    return attributes
  }
}
