import ComposableOTel
import OpenTelemetryApi
import OpenTelemetrySdk

/// Package-owned metric instruments and bounded SDK views.
public enum ComposableOTelMetricConfiguration {
  /// Registers a drop-by-default view plus one allowlisted view for every package metric.
  @discardableResult
  public static func registerViews(
    on builder: MeterProviderBuilder,
    policy: TelemetryPolicy
  ) -> MeterProviderBuilder {
    _ = builder.registerView(
      selector: InstrumentSelectorBuilder().build(),
      view: View.builder().withAggregation(aggregation: Aggregations.drop()).build()
    )

    for name in ComposableOTelSemantics.Metrics.all.sorted() {
      let allowedKeys = ComposableOTelSemantics.Metrics.attributeKeys(for: name)
      let viewBuilder = View.builder()
        .addAttributeFilter { allowedKeys.contains($0) }
        .addAttributeProcessor(
          processor: PolicyMetricAttributeProcessor(policy: policy, instrumentName: name)
        )
      if durationMetricNames.contains(name) {
        _ = viewBuilder.withAggregation(
          aggregation: Aggregations.explicitBucketHistogram(
            buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1_000, 5_000, 10_000, 30_000]
          )
        )
      }
      _ = builder.registerView(
        selector: InstrumentSelectorBuilder()
          .setInstrument(name: name)
          .setMeter(name: ComposableOTelMetadata.instrumentationName)
          .build(),
        view: viewBuilder.build()
      )
    }
    for schema in policy.catalog.counters.values.sorted(by: {
      $0.identity.name < $1.identity.name
    }) {
      _ = builder.registerView(
        selector: InstrumentSelectorBuilder()
          .setInstrument(name: schema.identity.name)
          .setMeter(name: ComposableOTelMetadata.instrumentationName)
          .build(),
        view: View.builder()
          .addAttributeFilter { schema.fieldKeys.contains($0) }
          .addAttributeProcessor(
            processor: ContractMetricAttributeProcessor(
              schema: schema,
              version: policy.catalog.contractVersion
            )
          )
          .build()
      )
    }
    return builder
  }

  /// Creates all package instruments with stable descriptions and UCUM-compatible units.
  public static func makeInstruments(meter: MeterSdk) -> MetricInstruments {
    .unsafeCustomSDK(
      actionsDispatched:
        meter
        .counterBuilder(name: ComposableOTelSemantics.Metrics.actionsDispatched)
        .setDescription("Number of reducer actions dispatched.")
        .setUnit("{action}")
        .build(),
      effectsStarted:
        meter
        .counterBuilder(name: ComposableOTelSemantics.Metrics.effectsStarted)
        .setDescription("Number of effects started.")
        .setUnit("{effect}")
        .build(),
      effectsCompleted:
        meter
        .counterBuilder(name: ComposableOTelSemantics.Metrics.effectsCompleted)
        .setDescription("Number of effects completed successfully.")
        .setUnit("{effect}")
        .build(),
      effectsCancelled:
        meter
        .counterBuilder(name: ComposableOTelSemantics.Metrics.effectsCancelled)
        .setDescription("Number of effects cancelled.")
        .setUnit("{effect}")
        .build(),
      effectsErrored:
        meter
        .counterBuilder(name: ComposableOTelSemantics.Metrics.effectsErrored)
        .setDescription("Number of effects that ended with an error.")
        .setUnit("{effect}")
        .build(),
      dependenciesCalled:
        meter
        .counterBuilder(name: ComposableOTelSemantics.Metrics.dependenciesCalled)
        .setDescription("Number of dependency operations called.")
        .setUnit("{call}")
        .build(),
      dependenciesErrored:
        meter
        .counterBuilder(name: ComposableOTelSemantics.Metrics.dependenciesErrored)
        .setDescription("Number of dependency operations that ended with an error.")
        .setUnit("{call}")
        .build(),
      navigationTransitions:
        meter
        .counterBuilder(name: ComposableOTelSemantics.Metrics.navigationTransitions)
        .setDescription("Number of navigation transitions.")
        .setUnit("{transition}")
        .build(),
      reducerDuration:
        meter
        .histogramBuilder(name: ComposableOTelSemantics.Metrics.reducerDuration)
        .setDescription("Synchronous reducer execution duration.")
        .setUnit("ms")
        .build(),
      effectDuration:
        meter
        .histogramBuilder(name: ComposableOTelSemantics.Metrics.effectDuration)
        .setDescription("Effect operation duration.")
        .setUnit("ms")
        .build(),
      dependencyDuration:
        meter
        .histogramBuilder(name: ComposableOTelSemantics.Metrics.dependencyDuration)
        .setDescription("Dependency operation duration.")
        .setUnit("ms")
        .build(),
      activeEffects:
        meter
        .upDownCounterBuilder(name: ComposableOTelSemantics.Metrics.activeEffects)
        .setDescription("Number of effects currently active.")
        .setUnit("{effect}")
        .build()
    )
  }

  package static func makeContractInstruments(
    meter: MeterSdk,
    catalog: TelemetryContractCatalog
  ) -> [TelemetryContractIdentity: any LongCounter] {
    Dictionary(
      uniqueKeysWithValues: catalog.counters.values.map { schema in
        (
          schema.identity,
          meter
            .counterBuilder(name: schema.identity.name)
            .setDescription(schema.description ?? "")
            .setUnit(schema.unit ?? "")
            .build() as any LongCounter
        )
      }
    )
  }

  private static let durationMetricNames: Set<String> = [
    ComposableOTelSemantics.Metrics.reducerDuration,
    ComposableOTelSemantics.Metrics.effectDuration,
    ComposableOTelSemantics.Metrics.dependencyDuration,
  ]
}

private struct ContractMetricAttributeProcessor: AttributeProcessor {
  let schema: TelemetryContractRecordSchema
  let version: TelemetryContractVersion

  func process(incoming: [String: AttributeValue]) -> [String: AttributeValue] {
    schema.sanitizedAttributes(incoming, version: version) ?? incoming
  }
}

private struct PolicyMetricAttributeProcessor: AttributeProcessor {
  let policy: TelemetryPolicy
  let instrumentName: String

  func process(incoming: [String: AttributeValue]) -> [String: AttributeValue] {
    policy.sanitizedMetricAttributes(incoming, instrumentName: instrumentName)
  }
}
