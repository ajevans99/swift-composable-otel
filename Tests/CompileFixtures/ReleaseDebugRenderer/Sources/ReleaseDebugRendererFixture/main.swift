import ComposableOTel

func unavailableInRelease(_ telemetry: TelemetryClient) {
  _ = TelemetryDebugConsoleRenderer.standardOutput
  _ = telemetry.log(
    .info,
    "Private \(42)",
    debugConsole: .standardOutput
  )
}

unavailableInRelease(.noop)
