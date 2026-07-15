import Dependencies
import DependenciesMacros
import OpenTelemetryApi

/// Reference-stable OpenTelemetry instruments for package-owned metrics.
///
/// Package-only SDK instrument wiring. Normal consumers record through ``TelemetryClient``.
package final class MetricInstruments: @unchecked Sendable {
  let actionsDispatched: any LongCounter
  let effectsStarted: any LongCounter
  let effectsCompleted: any LongCounter
  let effectsCancelled: any LongCounter
  let effectsErrored: any LongCounter
  let dependenciesCalled: any LongCounter
  let dependenciesErrored: any LongCounter
  let navigationTransitions: any LongCounter
  let reducerDuration: any DoubleHistogram
  let effectDuration: any DoubleHistogram
  let dependencyDuration: any DoubleHistogram
  let activeEffects: any LongUpDownCounter

  private init(
    actionsDispatched: any LongCounter,
    effectsStarted: any LongCounter,
    effectsCompleted: any LongCounter,
    effectsCancelled: any LongCounter,
    effectsErrored: any LongCounter,
    dependenciesCalled: any LongCounter,
    dependenciesErrored: any LongCounter,
    navigationTransitions: any LongCounter,
    reducerDuration: any DoubleHistogram,
    effectDuration: any DoubleHistogram,
    dependencyDuration: any DoubleHistogram,
    activeEffects: any LongUpDownCounter
  ) {
    self.actionsDispatched = actionsDispatched
    self.effectsStarted = effectsStarted
    self.effectsCompleted = effectsCompleted
    self.effectsCancelled = effectsCancelled
    self.effectsErrored = effectsErrored
    self.dependenciesCalled = dependenciesCalled
    self.dependenciesErrored = dependenciesErrored
    self.navigationTransitions = navigationTransitions
    self.reducerDuration = reducerDuration
    self.effectDuration = effectDuration
    self.dependencyDuration = dependencyDuration
    self.activeEffects = activeEffects
  }

  package static func unsafeCustomSDK(
    actionsDispatched: any LongCounter,
    effectsStarted: any LongCounter,
    effectsCompleted: any LongCounter,
    effectsCancelled: any LongCounter,
    effectsErrored: any LongCounter,
    dependenciesCalled: any LongCounter,
    dependenciesErrored: any LongCounter,
    navigationTransitions: any LongCounter,
    reducerDuration: any DoubleHistogram,
    effectDuration: any DoubleHistogram,
    dependencyDuration: any DoubleHistogram,
    activeEffects: any LongUpDownCounter
  ) -> MetricInstruments {
    MetricInstruments(
      actionsDispatched: actionsDispatched,
      effectsStarted: effectsStarted,
      effectsCompleted: effectsCompleted,
      effectsCancelled: effectsCancelled,
      effectsErrored: effectsErrored,
      dependenciesCalled: dependenciesCalled,
      dependenciesErrored: dependenciesErrored,
      navigationTransitions: navigationTransitions,
      reducerDuration: reducerDuration,
      effectDuration: effectDuration,
      dependencyDuration: dependencyDuration,
      activeEffects: activeEffects
    )
  }

  static func noop(meter: any Meter) -> MetricInstruments {
    unsafeCustomSDK(
      actionsDispatched: meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.actionsDispatched
      ).build(),
      effectsStarted: meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.effectsStarted
      ).build(),
      effectsCompleted: meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.effectsCompleted
      ).build(),
      effectsCancelled: meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.effectsCancelled
      ).build(),
      effectsErrored: meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.effectsErrored
      ).build(),
      dependenciesCalled: meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.dependenciesCalled
      ).build(),
      dependenciesErrored: meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.dependenciesErrored
      ).build(),
      navigationTransitions: meter.counterBuilder(
        name: ComposableOTelSemantics.Metrics.navigationTransitions
      ).build(),
      reducerDuration: meter.histogramBuilder(
        name: ComposableOTelSemantics.Metrics.reducerDuration
      ).build(),
      effectDuration: meter.histogramBuilder(
        name: ComposableOTelSemantics.Metrics.effectDuration
      ).build(),
      dependencyDuration: meter.histogramBuilder(
        name: ComposableOTelSemantics.Metrics.dependencyDuration
      ).build(),
      activeEffects: meter.upDownCounterBuilder(
        name: ComposableOTelSemantics.Metrics.activeEffects
      ).build()
    )
  }
}

struct SendableTracer: @unchecked Sendable {
  let underlying: any Tracer

  func spanBuilder(spanName: String) -> SpanBuilder {
    underlying.spanBuilder(spanName: spanName)
  }
}

struct SendableLogger: @unchecked Sendable {
  let underlying: any Logger

  func logRecordBuilder() -> LogRecordBuilder {
    underlying.logRecordBuilder()
  }
}

/// The finite synchronous outcome of recording a contract-bound operational event.
public enum TelemetryOperationalEventRecordingResult: Equatable, Sendable {
  /// The event was accepted into the configured telemetry pipeline.
  case recorded
  /// Operational events are disabled or the runtime permanently stopped accepting telemetry.
  case disabled
  /// The bounded queue rejected the event according to its overflow policy.
  case dropped
  /// The definition is unregistered or the payload does not satisfy its registered contract.
  case contractRejected
}

package struct TelemetryOperationalEventRecord: Sendable {
  package let eventName: String
  package let attributes: [String: AttributeValue]
}

package struct TelemetryOperationalEventRecorder: Sendable {
  private let operation:
    @Sendable (TelemetryOperationalEventRecord) -> TelemetryOperationalEventRecordingResult
  private let contractRejection: @Sendable () -> Void

  package init(
    _ operation:
      @escaping @Sendable (TelemetryOperationalEventRecord) ->
      TelemetryOperationalEventRecordingResult,
    contractRejection: @escaping @Sendable () -> Void = {}
  ) {
    self.operation = operation
    self.contractRejection = contractRejection
  }

  package func record(
    _ event: TelemetryOperationalEventRecord
  ) -> TelemetryOperationalEventRecordingResult {
    operation(event)
  }

  package func rejectContract() -> TelemetryOperationalEventRecordingResult {
    contractRejection()
    return .contractRejected
  }

  fileprivate static func logger(_ logger: SendableLogger) -> Self {
    Self { event in
      logger.logRecordBuilder()
        .setSeverity(Severity.info)
        .setAttributes(event.attributes)
        .setEventName(event.eventName)
        .emit()
      return .recorded
    }
  }
}

/// The dependency-injected runtime for bounded ComposableOTel instrumentation.
///
/// Use `TelemetryRuntime.client` for production or `TelemetryBootstrap.configure` for explicit
/// development stdout. Raw SDK construction is not part of the normal public product.
public struct TelemetryClient: Sendable {
  let tracer: SendableTracer
  let metrics: MetricInstruments
  let logger: SendableLogger
  private let operationalEventRecorder: TelemetryOperationalEventRecorder
  package let contracts: TelemetryContractRuntime

  public let policy: TelemetryPolicy

  private init(
    tracer: any Tracer,
    metrics: MetricInstruments,
    logger: any Logger,
    policy: TelemetryPolicy,
    contracts: TelemetryContractRuntime,
    operationalEventRecorder: TelemetryOperationalEventRecorder? = nil
  ) {
    let logger = SendableLogger(underlying: logger)
    self.tracer = SendableTracer(underlying: tracer)
    self.metrics = metrics
    self.logger = logger
    self.operationalEventRecorder = operationalEventRecorder ?? .logger(logger)
    self.policy = policy
    self.contracts = contracts
  }

  /// Builds a client around a custom SDK pipeline.
  ///
  /// - Warning: This bypasses the package-owned SDK boundary. Wrap every exporter with the privacy
  ///   wrappers from `ComposableOTelExporters`, configure package metric views, and provide only a
  ///   sanitized resource before using this client.
  package static func unsafeCustomSDK(
    tracer: any Tracer,
    metrics: MetricInstruments,
    logger: any Logger,
    policy: TelemetryPolicy
  ) -> TelemetryClient {
    TelemetryClient(
      tracer: tracer,
      metrics: metrics,
      logger: logger,
      policy: policy,
      contracts: TelemetryContractRuntime(
        catalog: policy.catalog,
        counters: [:],
        providerRetention: nil
      )
    )
  }

  package static func packageSDK(
    tracer: any Tracer,
    metrics: MetricInstruments,
    logger: any Logger,
    policy: TelemetryPolicy,
    contractCounters: [TelemetryContractIdentity: any LongCounter],
    contractProviderRetention: AnyObject? = nil,
    operationalEventRecorder: TelemetryOperationalEventRecorder? = nil
  ) -> TelemetryClient {
    TelemetryClient(
      tracer: tracer,
      metrics: metrics,
      logger: logger,
      policy: policy,
      contracts: TelemetryContractRuntime(
        catalog: policy.catalog,
        counters: contractCounters,
        providerRetention: contractProviderRetention
      ),
      operationalEventRecorder: operationalEventRecorder
    )
  }

  /// A provider-independent no-op dependency value.
  public static let noop: TelemetryClient = {
    let tracer = DefaultTracerProvider.instance.get(
      instrumentationName: ComposableOTelMetadata.instrumentationName,
      instrumentationVersion: ComposableOTelMetadata.version
    )
    let meter = DefaultMeterProvider.instance
      .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
      .setInstrumentationVersion(instrumentationVersion: ComposableOTelMetadata.version)
      .build()
    let logger = DefaultLoggerProvider.instance
      .loggerBuilder(instrumentationScopeName: ComposableOTelMetadata.instrumentationName)
      .setInstrumentationVersion(ComposableOTelMetadata.version)
      .build()
    return TelemetryClient(
      tracer: tracer,
      metrics: .noop(meter: meter),
      logger: logger,
      policy: TelemetryPolicy(signals: .disabled),
      contracts: .empty
    )
  }()

  func emitLog(
    severity: Severity,
    body: String,
    attributes: [String: AttributeValue]
  ) {
    guard policy.signals.logsEnabled else { return }
    logger.logRecordBuilder()
      .setSeverity(severity)
      .setBody(policy.sanitizedLogBody(.string(body)))
      .setAttributes(policy.sanitizedLogAttributes(attributes))
      .emit()
  }

  package func recordOperationalEvent(
    _ event: TelemetryOperationalEventRecord
  ) -> TelemetryOperationalEventRecordingResult {
    operationalEventRecorder.record(event)
  }

  package func rejectOperationalEventContract() -> TelemetryOperationalEventRecordingResult {
    operationalEventRecorder.rejectContract()
  }
}

private enum TelemetryClientKey: DependencyKey {
  static let liveValue = TelemetryClient.noop
  static let testValue = TelemetryClient.noop
}

extension DependencyValues {
  /// The bounded ComposableOTel instrumentation client.
  public var composableOTel: TelemetryClient {
    get { self[TelemetryClientKey.self] }
    set { self[TelemetryClientKey.self] = newValue }
  }
}
