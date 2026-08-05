import OpenTelemetryApi

enum ReducerTraceContext {
  @TaskLocal static var spanContext: SpanContext?
  @TaskLocal static var instrumentationSuppressed = false

  struct Capture: Sendable {
    let spanContext: SpanContext?
    let instrumentationSuppressed: Bool

    func withValues<Value>(
      _ operation: () async throws -> Value
    ) async rethrows -> Value {
      try await ReducerTraceContext.$instrumentationSuppressed.withValue(
        instrumentationSuppressed
      ) {
        try await ReducerTraceContext.$spanContext.withValue(spanContext) {
          try await operation()
        }
      }
    }
  }

  static func capture() -> Capture {
    Capture(
      spanContext: spanContext,
      instrumentationSuppressed: instrumentationSuppressed
    )
  }
}
