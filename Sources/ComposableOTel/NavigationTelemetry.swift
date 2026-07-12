import OpenTelemetryApi

extension TelemetryClient {
  /// Records a bounded navigation transition without route parameters or payloads.
  public func recordNavigation(_ operation: NavigationOperation, route: RouteID) {
    let route = policy.schema.bounded(route)
    let attributes: [String: AttributeValue] = [
      TCAAttributes.navigationOperation: .string(operation.rawValue),
      TCAAttributes.navigationRoute: .string(route.rawValue),
    ]

    if policy.signals.tracesEnabled {
      tracer
        .spanBuilder(spanName: ComposableOTelSemantics.Spans.navigation)
        .setSpanKind(spanKind: .internal)
        .setAttributes(policy.sanitizedSpanAttributes(attributes))
        .withActiveSpan { span in
          span.addEvent(name: ComposableOTelSemantics.Events.navigationChanged)
          span.status = .ok
        }
    }

    if policy.signals.metricsEnabled {
      var counter = metrics.navigationTransitions
      counter.add(
        value: 1,
        attributes: policy.sanitizedMetricAttributes(
          attributes,
          instrumentName: ComposableOTelSemantics.Metrics.navigationTransitions
        )
      )
    }

    emitLog(
      severity: .info,
      body: ComposableOTelSemantics.LogBodies.navigationChanged,
      attributes: attributes
    )
  }
}
