import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk

/// A production mobile OTLP runtime that owns all SDK and delivery lifecycle state.
///
/// Create one runtime at the application composition root, retain it for the process lifetime, and
/// inject ``client`` into feature dependencies. Exporter SDK types remain private to the runtime.
public final class TelemetryRuntime: @unchecked Sendable {
  public struct Configuration: Sendable {
    public var serviceName: ServiceID
    public var serviceVersion: ServiceVersionID?
    public var endpoints: OTLPEndpoints
    public var samplingRatio: Double
    public var policy: TelemetryPolicy
    public var resourceMode: TelemetryResourceMode
    public var traces: TelemetryBatchConfiguration
    public var logs: TelemetryBatchConfiguration
    public var metricExportInterval: Duration
    public var delivery: TelemetryDeliveryConfiguration
    public var persistence: TelemetryPersistenceConfiguration?
    public var defaultFlushTimeout: Duration
    public var backgroundFlushTimeout: Duration

    public init(
      serviceName: ServiceID,
      serviceVersion: ServiceVersionID? = nil,
      endpoints: OTLPEndpoints,
      samplingRatio: Double = 0.1,
      policy: TelemetryPolicy = .init(),
      resourceMode: TelemetryResourceMode = .native(environment: .production),
      traces: TelemetryBatchConfiguration = .init(),
      logs: TelemetryBatchConfiguration = .init(),
      metricExportInterval: Duration = .seconds(60),
      delivery: TelemetryDeliveryConfiguration = .init(),
      persistence: TelemetryPersistenceConfiguration? = nil,
      defaultFlushTimeout: Duration = .seconds(10),
      backgroundFlushTimeout: Duration = .seconds(5)
    ) {
      self.serviceName = serviceName
      self.serviceVersion = serviceVersion
      self.endpoints = endpoints
      self.samplingRatio = samplingRatio
      self.policy = policy
      self.resourceMode = resourceMode
      self.traces = traces
      self.logs = logs
      self.metricExportInterval = metricExportInterval
      self.delivery = delivery
      self.persistence = persistence
      self.defaultFlushTimeout = defaultFlushTimeout
      self.backgroundFlushTimeout = backgroundFlushTimeout
    }
  }

  public let client: TelemetryClient

  private let configuration: Configuration
  private let diagnosticsState: RuntimeDiagnosticsState
  private let delivery: RuntimeDeliveryEngine
  private let spanQueue: RuntimeBatchQueue<SpanData>
  private let logQueue: RuntimeBatchQueue<ReadableLogRecord>
  private let tracerProvider: UncheckedSendableBox<TracerProviderSdk>
  private let meterProvider: UncheckedSendableBox<MeterProviderSdk>
  private let customMeterProvider: UncheckedSendableBox<MeterProviderSdk>?
  private let loggerProvider: UncheckedSendableBox<LoggerProviderSdk>
  private let shutdownCoordinator = RuntimeShutdownCoordinator()
  private let discardCoordinator = RuntimeDiscardCoordinator()
  private let clock: TelemetryRuntimeClock
  private let providerLifecycleQueue = DispatchQueue(
    label: "com.swift-composable-otel.provider-lifecycle",
    qos: .utility
  )

  public convenience init(
    configuration: Configuration,
    transport: TelemetryHTTPTransport = .urlSession(),
    authenticator: TelemetryRequestAuthenticator,
    diagnostics: (@Sendable (TelemetryRuntimeDiagnosticEvent) -> Void)? = nil
  ) throws {
    try self.init(
      configuration: configuration,
      transport: transport,
      authenticator: authenticator,
      diagnosticHandler: diagnostics,
      dependencies: .live
    )
  }

  init(
    configuration: Configuration,
    transport: TelemetryHTTPTransport,
    authenticator: TelemetryRequestAuthenticator,
    diagnosticHandler: (@Sendable (TelemetryRuntimeDiagnosticEvent) -> Void)?,
    dependencies: TelemetryRuntimeDependencies
  ) throws {
    try Self.validate(configuration)
    self.configuration = configuration
    clock = dependencies.clock

    let diagnosticsState = RuntimeDiagnosticsState(handler: diagnosticHandler)
    self.diagnosticsState = diagnosticsState
    let persistence = try configuration.persistence.map {
      try RuntimePersistenceStore(
        configuration: $0,
        fileSystem: dependencies.fileSystem,
        diagnostics: diagnosticsState
      )
    }
    let delivery = RuntimeDeliveryEngine(
      configuration: configuration.delivery,
      transport: transport,
      authenticator: authenticator,
      diagnostics: diagnosticsState,
      dependencies: dependencies,
      persistence: persistence
    )
    self.delivery = delivery

    let boundary = TelemetryPrivacyBoundary(policy: configuration.policy)
    let traceHTTPClient = RuntimeOTLPHTTPClient(signal: .traces, delivery: delivery)
    let traceExporter = PrivacyPreservingSpanExporter(
      exporter: RuntimeByteBoundedSpanExporter(
        endpoint: configuration.endpoints.traces,
        maximumEncodedRequestBytes: configuration.delivery.maximumEncodedRequestBytes,
        deliveryClient: traceHTTPClient
      ),
      policy: configuration.policy
    )
    let spanQueue = RuntimeBatchQueue<SpanData>(
      configuration: configuration.traces,
      signal: .traces,
      diagnostics: diagnosticsState,
      clock: dependencies.clock,
      export: { spans, timeout in
        traceExporter.export(spans: spans, explicitTimeout: timeout) == .success
      },
      shutdownExporter: { timeout in
        traceExporter.shutdown(explicitTimeout: timeout)
      }
    )
    self.spanQueue = spanQueue
    let spanProcessor = RuntimeSpanProcessor(queue: spanQueue, boundary: boundary)

    let metricHTTPClient = RuntimeOTLPHTTPClient(signal: .metrics, delivery: delivery)
    let metricExporter = PrivacyPreservingMetricExporter(
      exporter: RuntimeByteBoundedMetricExporter(
        endpoint: configuration.endpoints.metrics,
        maximumEncodedRequestBytes: configuration.delivery.maximumEncodedRequestBytes,
        deliveryClient: metricHTTPClient
      ),
      policy: configuration.policy
    )
    let metricReader = PeriodicMetricReaderBuilder(exporter: metricExporter)
      .setInterval(timeInterval: configuration.metricExportInterval.runtimeSeconds)
      .build()

    let logHTTPClient = RuntimeOTLPHTTPClient(signal: .logs, delivery: delivery)
    let logExporter = PrivacyPreservingLogRecordExporter(
      exporter: RuntimeByteBoundedLogExporter(
        endpoint: configuration.endpoints.logs,
        maximumEncodedRequestBytes: configuration.delivery.maximumEncodedRequestBytes,
        deliveryClient: logHTTPClient
      ),
      policy: configuration.policy
    )
    let logQueue = RuntimeBatchQueue<ReadableLogRecord>(
      configuration: configuration.logs,
      signal: .logs,
      diagnostics: diagnosticsState,
      clock: dependencies.clock,
      export: { records, timeout in
        logExporter.export(logRecords: records, explicitTimeout: timeout) == .success
      },
      shutdownExporter: { timeout in
        logExporter.shutdown(explicitTimeout: timeout)
      }
    )
    self.logQueue = logQueue
    let logProcessor = RuntimeLogRecordProcessor(queue: logQueue, boundary: boundary)

    let resource = try TelemetryBootstrap.makeResource(
      serviceName: configuration.serviceName,
      serviceVersion: configuration.serviceVersion,
      resourceMode: configuration.resourceMode,
      policy: configuration.policy
    )
    let sampler = Samplers.parentBased(
      root: Samplers.traceIdRatio(ratio: configuration.samplingRatio)
    )
    let spanLimits = SpanLimits()
      .settingAttributeCountLimit(16)
      .settingAttributeValueLengthLimit(
        UInt(TelemetryStringValue.maximumLength)
      )
      .settingEventCountLimit(4)
      .settingLinkCountLimit(0)
      .settingAttributePerEventCountLimit(8)
      .settingAttributePerLinkCountLimit(0)
    let tracerProvider = TracerProviderBuilder()
      .with(resource: resource)
      .with(spanLimits: spanLimits)
      .with(sampler: sampler)
      .add(spanProcessor: spanProcessor)
      .build()
    self.tracerProvider = UncheckedSendableBox(tracerProvider)

    let meterBuilder = MeterProviderSdk.builder()
      .setResource(resource: resource)
      .registerMetricReader(reader: metricReader)
    ComposableOTelMetricConfiguration.registerViews(
      on: meterBuilder,
      policy: configuration.policy
    )
    let meterProvider = meterBuilder.build()
    self.meterProvider = UncheckedSendableBox(meterProvider)

    let customMeterProvider: MeterProviderSdk?
    let contractCounters: [TelemetryContractIdentity: any LongCounter]
    if configuration.policy.catalog.counters.isEmpty {
      customMeterProvider = nil
      contractCounters = [:]
    } else {
      let customHTTPClient = RuntimeOTLPHTTPClient(signal: .metrics, delivery: delivery)
      let customRawExporter = RuntimeByteBoundedMetricExporter(
        endpoint: configuration.endpoints.metrics,
        maximumEncodedRequestBytes: configuration.delivery.maximumEncodedRequestBytes,
        maximumPointsPerRequest: configuration.delivery.maximumContractMetricPointsPerRequest,
        diagnostics: diagnosticsState,
        deliveryClient: customHTTPClient
      )
      let customMetricExporter = PrivacyPreservingMetricExporter(
        exporter: DeltaCounterMetricExporter(exporter: customRawExporter),
        policy: configuration.policy
      )
      let customReader = PeriodicMetricReaderBuilder(exporter: customMetricExporter)
        .setInterval(timeInterval: configuration.metricExportInterval.runtimeSeconds)
        .build()
      let customBuilder = MeterProviderSdk.builder()
        .setResource(resource: resource)
        .registerMetricReader(reader: customReader)
      ComposableOTelMetricConfiguration.registerViews(
        on: customBuilder,
        policy: configuration.policy
      )
      let provider = customBuilder.build()
      let customMeter =
        provider
        .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
        .setInstrumentationVersion(
          instrumentationVersion: ComposableOTelMetadata.version
        )
        .build()
      customMeterProvider = provider
      contractCounters = ComposableOTelMetricConfiguration.makeContractInstruments(
        meter: customMeter,
        catalog: configuration.policy.catalog
      )
    }
    self.customMeterProvider = customMeterProvider.map(UncheckedSendableBox.init)

    let loggerProvider = LoggerProviderSdk(
      resource: resource,
      logRecordProcessors: [logProcessor]
    )
    self.loggerProvider = UncheckedSendableBox(loggerProvider)

    let tracer = tracerProvider.get(
      instrumentationName: ComposableOTelMetadata.instrumentationName,
      instrumentationVersion: ComposableOTelMetadata.version
    )
    let meter =
      meterProvider
      .meterBuilder(name: ComposableOTelMetadata.instrumentationName)
      .setInstrumentationVersion(
        instrumentationVersion: ComposableOTelMetadata.version
      )
      .build()
    let logger =
      loggerProvider
      .loggerBuilder(instrumentationScopeName: ComposableOTelMetadata.instrumentationName)
      .setInstrumentationVersion(ComposableOTelMetadata.version)
      .build()
    client = TelemetryClient.packageSDK(
      tracer: tracer,
      metrics: ComposableOTelMetricConfiguration.makeInstruments(meter: meter),
      logger: logger,
      policy: configuration.policy,
      contractCounters: contractCounters,
      contractProviderRetention: customMeterProvider
    )

    Task {
      await delivery.start()
    }
  }

  /// Current non-recursive exporter diagnostics.
  public var diagnostics: TelemetryRuntimeDiagnostics {
    diagnosticsState.snapshot()
  }

  /// Updates a reachability or policy hint without claiming that export will succeed.
  public func setExportCondition(_ condition: TelemetryExportCondition) async {
    await delivery.setCondition(condition)
  }

  /// Resumes eligible delivery after the host application becomes active.
  public func applicationDidBecomeActive() async {
    await delivery.start()
  }

  /// Performs a bounded best-effort flush when the host application backgrounds.
  ///
  /// A host that acquired background execution time should pass its remaining budget. This method
  /// never acquires UIKit or BackgroundTasks resources itself.
  public func applicationDidEnterBackground(
    remainingTime: Duration? = nil
  ) async -> TelemetryRuntimeOperationResult {
    let configured = configuration.backgroundFlushTimeout.runtimeSeconds
    let timeout =
      remainingTime.map {
        Duration.runtimeSeconds(min(configured, max(0, $0.runtimeSeconds)))
      } ?? configuration.backgroundFlushTimeout
    return await flush(
      operation: .background,
      deadline: clock.now().addingTimeInterval(timeout.runtimeSeconds)
    )
  }

  /// Flushes all signals and encoded delivery within a bounded best-effort deadline.
  public func forceFlush(
    timeout: Duration? = nil
  ) async -> TelemetryRuntimeOperationResult {
    let timeout = timeout ?? configuration.defaultFlushTimeout
    return await flush(
      operation: .forceFlush,
      deadline: clock.now().addingTimeInterval(timeout.runtimeSeconds)
    )
  }

  /// Flushes, stops all signal pipelines, and cancels remaining work exactly once.
  ///
  /// Timed-out persisted batches remain available for a later runtime launch. Without persistence,
  /// pending batches are deterministically dropped.
  public func shutdown(
    timeout: Duration? = nil
  ) async -> TelemetryRuntimeOperationResult {
    await shutdownCoordinator.perform {
      let timeout = timeout ?? self.configuration.defaultFlushTimeout
      let deadline = self.clock.now().addingTimeInterval(timeout.runtimeSeconds)
      self.spanQueue.stopAccepting()
      self.logQueue.stopAccepting()
      let result = await self.flush(operation: .shutdown, deadline: deadline)

      async let spans: Void = self.spanQueue.shutdown()
      async let logs: Void = self.logQueue.shutdown()
      _ = await (spans, logs)
      await self.performProviderOperation {
        _ = self.meterProvider.value.shutdown()
        _ = self.customMeterProvider?.value.shutdown()
      }

      await self.delivery.shutdown(retainPersisted: self.configuration.persistence != nil)
      return result
    }
  }

  /// Permanently stops this runtime and deletes all unsent in-memory and persisted telemetry.
  ///
  /// Swap the host application's telemetry dependency to `TelemetryClient.noop` before invoking
  /// this operation. Unlike ``shutdown(timeout:)``, this method never flushes pending telemetry and
  /// cannot be reversed by a later lifecycle or export-condition update.
  public func disableAndDiscardPending() async -> TelemetryRuntimeOperationResult {
    spanQueue.stopAccepting()
    logQueue.stopAccepting()

    return await discardCoordinator.perform {
      let baseline = self.diagnosticsState.snapshot()
      let deliveryOutcome = await self.delivery.disableAndDiscardPending()
      async let traces = self.spanQueue.disableAndDiscardPending()
      async let logs = self.logQueue.disableAndDiscardPending()
      _ = await (traces, logs)
      await self.performProviderOperation {
        self.tracerProvider.value.shutdown()
        _ = self.meterProvider.value.shutdown()
        _ = self.customMeterProvider?.value.shutdown()
      }

      let current = self.diagnosticsState.snapshot()
      func result(
        for signal: TelemetryRuntimeSignal,
        enabled: Bool
      ) -> TelemetrySignalOperationResult {
        let discarded = max(
          0,
          current.signal(signal).droppedItems - baseline.signal(signal).droppedItems
        )
        let signalFailures = deliveryOutcome.failedBySignal[signal, default: 0]
        let pending = signalFailures
        let status: TelemetrySignalOperationResult.Status
        if signalFailures > 0 {
          status = .failed
        } else if !enabled {
          status = .disabled
        } else {
          status = .success
        }
        return TelemetrySignalOperationResult(
          status: status,
          pendingItems: pending,
          droppedItems: discarded
        )
      }

      return TelemetryRuntimeOperationResult(
        operation: .disableAndDiscardPending,
        traces: result(
          for: .traces,
          enabled: self.configuration.policy.signals.tracesEnabled
        ),
        metrics: result(
          for: .metrics,
          enabled: self.configuration.policy.signals.metricsEnabled
        ),
        logs: result(
          for: .logs,
          enabled: self.configuration.policy.signals.logsEnabled
        ),
        persistedItems: deliveryOutcome.remainingPersistedItems
      )
    }
  }

  private func flush(
    operation: TelemetryRuntimeOperationResult.Operation,
    deadline: Date
  ) async -> TelemetryRuntimeOperationResult {
    async let spans: Void = spanQueue.forceFlush()
    async let logs: Void = logQueue.forceFlush()
    async let metricsSucceeded: Bool = performProviderOperation {
      let native = self.meterProvider.value.forceFlush() == .success
      let custom = self.customMeterProvider?.value.forceFlush() != .failure
      return native && custom
    }
    _ = await (spans, logs)
    let metricSucceeded = await metricsSucceeded

    let remaining = max(0, deadline.timeIntervalSince(clock.now()))
    let deliveryCompleted = await delivery.flush(timeout: .runtimeSeconds(remaining))
    return await operationResult(
      operation: operation,
      deliveryCompleted: deliveryCompleted,
      metricSucceeded: metricSucceeded
    )
  }

  private func operationResult(
    operation: TelemetryRuntimeOperationResult.Operation,
    deliveryCompleted: Bool,
    metricSucceeded: Bool
  ) async -> TelemetryRuntimeOperationResult {
    let current = diagnosticsState.snapshot()
    let pending = await delivery.pendingBySignal()

    func result(
      for signal: TelemetryRuntimeSignal,
      enabled: Bool,
      extraFailure: Bool = false
    ) -> TelemetrySignalOperationResult {
      guard enabled else {
        return .init(status: .disabled, pendingItems: 0, droppedItems: 0)
      }
      let dropped = current.signal(signal).droppedItems
      let status: TelemetrySignalOperationResult.Status
      if !deliveryCompleted || pending[signal, default: 0] > 0 {
        status = .timedOut
      } else if dropped > 0 || extraFailure {
        status = .failed
      } else {
        status = .success
      }
      return .init(
        status: status,
        pendingItems: pending[signal, default: 0],
        droppedItems: dropped
      )
    }

    return TelemetryRuntimeOperationResult(
      operation: operation,
      traces: result(for: .traces, enabled: configuration.policy.signals.tracesEnabled),
      metrics: result(
        for: .metrics,
        enabled: configuration.policy.signals.metricsEnabled,
        extraFailure: !metricSucceeded
      ),
      logs: result(for: .logs, enabled: configuration.policy.signals.logsEnabled),
      persistedItems: current.persistedItems
    )
  }

  private static func validate(_ configuration: Configuration) throws {
    for signal in TelemetryRuntimeSignal.allCases {
      let endpoint = configuration.endpoints.endpoint(for: signal)
      guard endpoint.scheme?.lowercased() == "https" else {
        throw TelemetryRuntimeConfigurationError.endpointMustUseTLS(signal: signal)
      }
      guard endpoint.host?.isEmpty == false else {
        throw TelemetryRuntimeConfigurationError.endpointMissingHost(signal: signal)
      }
      guard endpoint.user == nil, endpoint.password == nil else {
        throw TelemetryRuntimeConfigurationError.endpointContainsCredentials(signal: signal)
      }
      guard endpoint.query == nil, endpoint.fragment == nil else {
        throw TelemetryRuntimeConfigurationError.endpointContainsQueryOrFragment(signal: signal)
      }
    }

    guard configuration.samplingRatio.isFinite,
      (0...1).contains(configuration.samplingRatio)
    else {
      throw TelemetryRuntimeConfigurationError.invalidSamplingRatio
    }
    guard valid(batch: configuration.traces), valid(batch: configuration.logs) else {
      throw TelemetryRuntimeConfigurationError.invalidBatchLimits
    }

    let delivery = configuration.delivery
    let retry = delivery.retry
    guard delivery.maximumPendingBatches > 0,
      delivery.maximumEncodedRequestBytes > 0,
      delivery.maximumContractMetricPointsPerRequest > 0,
      valid(duration: delivery.requestTimeout),
      retry.maximumAttempts > 0,
      valid(duration: retry.initialBackoff),
      valid(duration: retry.maximumBackoff),
      retry.initialBackoff <= retry.maximumBackoff,
      retry.jitterRatio.isFinite,
      (0...1).contains(retry.jitterRatio),
      valid(duration: configuration.metricExportInterval),
      valid(duration: configuration.defaultFlushTimeout),
      valid(duration: configuration.backgroundFlushTimeout)
    else {
      throw TelemetryRuntimeConfigurationError.invalidDeliveryLimits
    }
    let maximumContractPoints = configuration.policy.catalog.counters.values.reduce(0) {
      partial,
      schema in
      let added = partial.addingReportingOverflow(schema.maximumSeries ?? 0)
      return added.overflow ? Int.max : added.partialValue
    }
    guard maximumContractPoints <= delivery.maximumContractMetricPointsPerRequest else {
      throw TelemetryRuntimeConfigurationError.invalidDeliveryLimits
    }

    if let persistence = configuration.persistence {
      guard persistence.directory.isFileURL,
        persistence.maximumBytes > 0,
        valid(duration: persistence.maximumAge)
      else {
        throw TelemetryRuntimeConfigurationError.invalidPersistenceLimits
      }
    }
    if case .strict(let resource) = configuration.resourceMode {
      guard configuration.policy.catalog.contains(resource.identity) else {
        throw TelemetryRuntimeConfigurationError.invalidResourceContract
      }
    }
  }

  private static func valid(batch: TelemetryBatchConfiguration) -> Bool {
    batch.maximumQueueSize > 0
      && batch.maximumBatchSize > 0
      && batch.maximumBatchSize <= batch.maximumQueueSize
      && valid(duration: batch.scheduledDelay)
      && valid(duration: batch.exportTimeout)
  }

  private static func valid(duration: Duration) -> Bool {
    duration.runtimeSeconds.isFinite && duration > .zero
  }

  private func performProviderOperation<Value: Sendable>(
    _ operation: @escaping @Sendable () -> Value
  ) async -> Value {
    await withCheckedContinuation { continuation in
      providerLifecycleQueue.async {
        continuation.resume(returning: operation())
      }
    }
  }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

private actor RuntimeShutdownCoordinator {
  private var task: Task<TelemetryRuntimeOperationResult, Never>?
  private var result: TelemetryRuntimeOperationResult?

  func perform(
    _ operation: @escaping @Sendable () async -> TelemetryRuntimeOperationResult
  ) async -> TelemetryRuntimeOperationResult {
    if let result {
      return result
    }

    if let task {
      return await task.value
    }
    let task = Task {
      await operation()
    }
    self.task = task
    let result = await task.value
    self.result = result
    self.task = nil
    return result
  }
}

private actor RuntimeDiscardCoordinator {
  private var task: Task<TelemetryRuntimeOperationResult, Never>?
  private var result: TelemetryRuntimeOperationResult?

  func perform(
    _ operation: @escaping @Sendable () async -> TelemetryRuntimeOperationResult
  ) async -> TelemetryRuntimeOperationResult {
    if let result {
      return result
    }
    if let task {
      return await task.value
    }
    let task = Task {
      await operation()
    }
    self.task = task
    let result = await task.value
    if result.succeeded {
      self.result = result
    }
    self.task = nil
    return result
  }
}
