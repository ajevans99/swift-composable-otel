import OpenTelemetryApi

enum ReducerTraceContext {
  @TaskLocal static var spanContext: SpanContext?
}
