import OpenTelemetryApi

extension TelemetryClient {
  /// Records a bounded navigation transition without route parameters or payloads.
  ///
  /// The `tca.navigation` span is parented to the current reducer or effect when one is active, and
  /// the `tca.navigation.changed` log is correlated with it. Pass a static ``RouteID`` such as
  /// `"plan-detail"`; never derive it from a parameterized path.
  public func recordNavigation(_ operation: NavigationOperation, route: RouteID) {
    guard !ReducerTraceContext.instrumentationSuppressed else { return }
    let route = policy.schema.bounded(route)
    let attributes: [String: AttributeValue] = [
      TCAAttributes.navigationOperation: .string(operation.rawValue),
      TCAAttributes.navigationRoute: .string(route.rawValue),
    ]
    let signalAttributes = ReducerTraceContext.addingFeature(to: attributes)

    var spanContext: SpanContext?
    if policy.signals.tracesEnabled {
      let builder =
        tracer
        .spanBuilder(spanName: ComposableOTelSemantics.Spans.navigation)
        .setSpanKind(spanKind: .internal)
        .setAttributes(policy.sanitizedSpanAttributes(signalAttributes))
      if let parent = ReducerTraceContext.spanContext {
        builder.setParent(parent)
      }
      spanContext = builder.withActiveSpan { span in
        span.addEvent(name: ComposableOTelSemantics.Events.navigationChanged)
        span.status = .ok
        return span.context
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
      eventName: ComposableOTelSemantics.LogEvents.navigationChanged,
      body: ComposableOTelSemantics.LogBodies.navigationChanged,
      attributes: signalAttributes,
      spanContext: spanContext
    )
  }
}
