import ComposableOTel
import ComposableOTelExporters

func unavailable(policy: TelemetryPolicy) {
  _ = TelemetryClient.unsafeCustomSDK
  _ = MetricInstruments.self
  _ = policy.sanitizedSpanAttributes([:])
  _ = PrivacyPreservingSpanExporter.self
  _ = ComposableOTelMetricConfiguration.self
}

unavailable(policy: TelemetryPolicy())
