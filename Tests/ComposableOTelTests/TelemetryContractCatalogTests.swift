import ComposableOTelTesting
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

private struct ContractSignalPayload: Sendable {
  let flow: TelemetryEnumValue
  let phase: TelemetryEnumValue
  let result: TelemetryEnumValue
  let errorCode: TelemetryEnumValue?
  let retryable: Bool
  let attempt: Int64
}

private struct ContractResourcePayload: Sendable {
  let namespace: TelemetryStringValue
  let platform: TelemetryEnumValue
  let build: Int64
  let releaseChannel: TelemetryEnumValue
  let deviceClass: TelemetryEnumValue
  let distribution: TelemetryEnumValue
  let commit: TelemetryStringValue
  let serviceTier: TelemetryEnumValue
}

private struct ContractFixture {
  let span: TelemetrySpanDefinition<ContractSignalPayload>
  let effectSpan: TelemetrySpanDefinition<ContractSignalPayload>
  let dependencySpan: TelemetrySpanDefinition<ContractSignalPayload>
  let startedLog: TelemetryLogDefinition<ContractSignalPayload>
  let completedLog: TelemetryLogDefinition<ContractSignalPayload>
  let failedLog: TelemetryLogDefinition<ContractSignalPayload>
  let rejectedLog: TelemetryLogDefinition<ContractSignalPayload>
  let counter: TelemetryCounterDefinition<ContractSignalPayload>
  let resource: TelemetryResourceDefinition<ContractResourcePayload>
  let resourceValue: TelemetryResourceValue
  let policy: TelemetryPolicy

  static func make() throws -> Self {
    let flowKey = try TelemetryFieldKey("contract.flow")
    let phaseKey = try TelemetryFieldKey("contract.phase")
    let resultKey = try TelemetryFieldKey("contract.result")
    let errorCodeKey = try TelemetryFieldKey("contract.error_code")
    let retryableKey = try TelemetryFieldKey("contract.retryable")
    let attemptKey = try TelemetryFieldKey("contract.attempt")
    let flows: Set<TelemetryEnumValue> = [try .init("checkout"), try .init("refresh")]
    let phases: Set<TelemetryEnumValue> = [try .init("begin"), try .init("end")]
    let results: Set<TelemetryEnumValue> = [
      try .init("success"), try .init("cancelled"), try .init("error"),
    ]
    let errorCodes: Set<TelemetryEnumValue> = [try .init("none"), try .init("unavailable")]
    let signalFields: [TelemetryField<ContractSignalPayload>] = [
      try .enumeration(flowKey, allowedValues: flows) { $0.flow },
      try .enumeration(phaseKey, allowedValues: phases) { $0.phase },
      try .enumeration(resultKey, allowedValues: results) { $0.result },
      try .enumeration(errorCodeKey, allowedValues: errorCodes, presence: .optional) {
        $0.errorCode
      },
      .boolean(retryableKey) { $0.retryable },
      try .integer(attemptKey, range: 0...4) { $0.attempt },
    ]
    let validate: @Sendable (ContractSignalPayload) -> Bool = {
      ($0.result.rawValue == "error") == ($0.errorCode != nil)
    }
    let validateFields: @Sendable ([TelemetryFieldKey: TelemetryScalarValue]) -> Bool = {
      guard case .enumeration(let result) = $0[resultKey] else { return false }
      return (result.rawValue == "error") == ($0[errorCodeKey] != nil)
    }
    let span = try TelemetrySpanDefinition(
      name: .init("contract.flow"),
      fields: signalFields,
      validate: validate,
      validationRule: .init("error-requires-code"),
      validateFields: validateFields
    )
    let effectSpan = try TelemetrySpanDefinition(
      name: .init("contract.effect"),
      fields: signalFields,
      validate: validate,
      validationRule: .init("error-requires-code"),
      validateFields: validateFields
    )
    let dependencySpan = try TelemetrySpanDefinition(
      name: .init("contract.dependency"),
      fields: signalFields,
      validate: validate,
      validationRule: .init("error-requires-code"),
      validateFields: validateFields
    )
    func log(
      _ name: String,
      severity: TelemetryLogSeverity
    ) throws -> TelemetryLogDefinition<ContractSignalPayload> {
      try TelemetryLogDefinition(
        eventName: .init(name),
        severity: severity,
        bodyPolicy: .none,
        fields: signalFields,
        validate: validate,
        validationRule: .init("error-requires-code"),
        validateFields: validateFields
      )
    }
    let startedLog = try log("contract.flow.started", severity: .info)
    let completedLog = try log("contract.flow.completed", severity: .info)
    let failedLog = try log("contract.flow.failed", severity: .error)
    let rejectedLog = try log("contract.flow.rejected", severity: .error)
    let counter = try TelemetryCounterDefinition(
      name: .init("contract.events"),
      unit: .init("{event}"),
      description: .init("contract-events"),
      maximumSeries: 6,
      fields: [
        try .enumeration(flowKey, allowedValues: flows) {
          (payload: ContractSignalPayload) in payload.flow
        },
        try .enumeration(resultKey, allowedValues: results) {
          (payload: ContractSignalPayload) in payload.result
        },
      ]
    )

    let namespaceKey = try TelemetryFieldKey("service.namespace")
    let platformKey = try TelemetryFieldKey("app.platform")
    let buildKey = try TelemetryFieldKey("app.build")
    let releaseKey = try TelemetryFieldKey("app.release_channel")
    let deviceKey = try TelemetryFieldKey("device.class")
    let distributionKey = try TelemetryFieldKey("app.distribution")
    let commitKey = try TelemetryFieldKey("app.commit")
    let tierKey = try TelemetryFieldKey("service.tier")
    let resource = try TelemetryResourceDefinition<ContractResourcePayload>(
      name: .init("contract.resource"),
      fields: [
        try .string(namespaceKey) { $0.namespace },
        try .enumeration(platformKey, allowedValues: [try .init("ios"), try .init("macos")]) {
          $0.platform
        },
        try .integer(buildKey, range: 0...1_000_000) { $0.build },
        try .enumeration(
          releaseKey,
          allowedValues: [try .init("debug"), try .init("staging"), try .init("production")]
        ) { $0.releaseChannel },
        try .enumeration(
          deviceKey,
          allowedValues: [try .init("phone"), try .init("tablet"), try .init("desktop")]
        ) { $0.deviceClass },
        try .enumeration(
          distributionKey,
          allowedValues: [try .init("internal"), try .init("store")]
        ) { $0.distribution },
        try .string(commitKey) { $0.commit },
        try .enumeration(
          tierKey,
          allowedValues: [try .init("free"), try .init("paid")]
        ) { $0.serviceTier },
      ]
    )
    let resourceValue = try resource.makeValue(
      ContractResourcePayload(
        namespace: .init("sample-app"),
        platform: .init("ios"),
        build: 42,
        releaseChannel: .init("staging"),
        deviceClass: .init("phone"),
        distribution: .init("internal"),
        commit: .init("abcdef1"),
        serviceTier: .init("paid")
      )
    )
    let catalog = try TelemetryContractCatalog(
      contractVersion: .init(7),
      spans: [.init(span), .init(effectSpan), .init(dependencySpan)],
      logs: [
        .init(startedLog), .init(completedLog), .init(failedLog), .init(rejectedLog),
      ],
      counters: [.init(counter)],
      resources: [.init(resource)]
    )
    return Self(
      span: span,
      effectSpan: effectSpan,
      dependencySpan: dependencySpan,
      startedLog: startedLog,
      completedLog: completedLog,
      failedLog: failedLog,
      rejectedLog: rejectedLog,
      counter: counter,
      resource: resource,
      resourceValue: resourceValue,
      policy: TelemetryPolicy(
        schema: testSchema,
        catalog: catalog,
        signals: .init(tracesEnabled: true, metricsEnabled: true, logsEnabled: true)
      )
    )
  }

  func payload(
    result: String = "success",
    errorCode: String? = nil
  ) throws -> ContractSignalPayload {
    try ContractSignalPayload(
      flow: .init("checkout"),
      phase: .init("end"),
      result: .init(result),
      errorCode: errorCode.map { try TelemetryEnumValue($0) },
      retryable: false,
      attempt: 1
    )
  }
}

@Suite("Typed external contract catalog", .serialized)
struct TelemetryContractCatalogTests {
  @Test("supports only the finite deployment environment enum")
  func deploymentEnvironments() {
    for environment in TelemetryDeploymentEnvironment.allCases {
      let resource = TelemetryBootstrap.makeResource(
        serviceName: "test-suite",
        serviceVersion: nil,
        deploymentEnvironment: environment,
        policy: testPolicy()
      )
      #expect(
        resource.attributes["deployment.environment.name"]
          == .string(environment.rawValue)
      )
    }
  }

  @Test("emits exact typed resource, span, bodyless logs, and delta counter")
  func exactWireContracts() async throws {
    let fixture = try ContractFixture.make()
    let (client, collectors) = TelemetryClient.test(
      deploymentEnvironment: .staging,
      resource: fixture.resourceValue,
      policy: fixture.policy
    )
    let payload = try fixture.payload()

    try await withDependencies {
      $0.composableOTel = client
    } operation: {
      try await client.withSpan(fixture.span, payload: payload) {
        try client.record(fixture.startedLog, payload: payload)
        try client.record(fixture.completedLog, payload: payload)
        try client.record(fixture.failedLog, payload: payload)
        try client.record(fixture.rejectedLog, payload: payload)
        try client.add(fixture.counter, delta: .init(3), payload: payload)
        try await client.withSpan(fixture.effectSpan, payload: payload) {
          try await client.withSpan(fixture.dependencySpan, payload: payload) {}
        }
      }

    }
    collectors.forceFlush()

    let span = try #require(collectors.decodedSpans(for: fixture.span).first)
    #expect(span.name == "contract.flow")
    #expect(span.contractVersion == 7)
    #expect(span.fields.count == 5)
    #expect(span.fields["contract.attempt"] == .integer(1))
    #expect(span.fields["contract.retryable"] == .boolean(false))

    let rawSpan = try #require(collectors.spans.spans(named: "contract.flow").first)
    let effect = try #require(collectors.spans.spans(named: "contract.effect").first)
    let dependency = try #require(collectors.spans.spans(named: "contract.dependency").first)
    #expect(effect.parentSpanId == rawSpan.spanId)
    #expect(dependency.parentSpanId == effect.spanId)
    #expect(effect.traceId == rawSpan.traceId)
    #expect(dependency.traceId == rawSpan.traceId)

    let definitions = [
      fixture.startedLog, fixture.completedLog, fixture.failedLog, fixture.rejectedLog,
    ]
    let decodedLogs = definitions.flatMap { collectors.decodedLogs(for: $0) }
    #expect(decodedLogs.count == 4)
    #expect(decodedLogs.allSatisfy { $0.body == nil && $0.contractVersion == 7 })
    #expect(decodedLogs.map(\.severity) == [.info, .info, .error, .error])

    let counter = try #require(collectors.decodedCounters(for: fixture.counter).first)
    #expect(counter.unit == "{event}")
    #expect(counter.isMonotonic)
    #expect(counter.temporality == .delta)
    #expect(counter.value == 3)
    #expect(counter.contractVersion == 7)
    #expect(counter.fields.count == 2)

    let resource = try #require(collectors.decodedResource(for: fixture.resource))
    #expect(resource.contractVersion == 7)
    #expect(resource.fields.count == 8)
    #expect(resource.fields["app.build"] == .integer(42))
    #expect(rawSpan.resource.attributes["deployment.environment.name"] == .string("staging"))
  }

  @Test("custom spans preserve error and cancellation outcomes")
  func spanOutcomes() async throws {
    enum ExpectedFailure: Error {
      case failed
    }
    let fixture = try ContractFixture.make()
    let (client, collectors) = TelemetryClient.test(policy: fixture.policy)
    let errorPayload = try fixture.payload(result: "error", errorCode: "unavailable")

    do {
      let _: Void = try await client.withSpan(fixture.span, payload: errorPayload) {
        throw ExpectedFailure.failed
      }
      Issue.record("Expected custom span failure")
    } catch is ExpectedFailure {
    }
    let task = Task {
      try await client.withSpan(fixture.span, payload: try fixture.payload()) {
        try await Task.sleep(for: .seconds(30))
      }
    }
    await Task.yield()
    task.cancel()
    _ = try? await task.value
    collectors.forceFlush()

    let spans = collectors.spans.spans(named: fixture.span.name.rawValue)
    #expect(spans.count == 2)
    #expect(spans.contains { $0.status.isError })
    #expect(
      spans.contains {
        $0.status == .unset
          && $0.events.map(\.name).contains(ComposableOTelSemantics.Events.effectCancelled)
      }
    )
  }

  @Test("production pipeline captures encoded registered signals without network")
  func encodedCapture() async throws {
    let fixture = try ContractFixture.make()
    let capture = InMemoryEncodedRequestCollector()
    var configuration = TelemetryRuntime.Configuration(
      serviceName: "test-suite",
      endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
      samplingRatio: 1,
      policy: fixture.policy,
      deploymentEnvironment: .staging,
      resource: fixture.resourceValue,
      traces: .init(maximumQueueSize: 1, maximumBatchSize: 1),
      logs: .init(maximumQueueSize: 1, maximumBatchSize: 1),
      metricExportInterval: .seconds(3_600)
    )
    configuration.delivery.maximumEncodedRequestBytes = 64 * 1_024
    let runtime = try TelemetryRuntime(
      configuration: configuration,
      transport: capture.transport,
      authenticator: .none
    )
    let payload = try fixture.payload()

    try await runtime.client.withSpan(fixture.span, payload: payload) {}
    try runtime.client.record(fixture.startedLog, payload: payload)
    try runtime.client.add(fixture.counter, delta: .init(1), payload: payload)
    let result = await runtime.forceFlush(timeout: .seconds(2))

    #expect(result.succeeded)
    #expect(Set(capture.requests.compactMap(\.signal)) == [.traces, .metrics, .logs])
    #expect(capture.requests.allSatisfy { !$0.body.isEmpty && $0.body.count <= 64 * 1_024 })
    _ = await runtime.shutdown(timeout: .seconds(1))
  }

  @Test("rejects invalid conditional payloads and unregistered definitions")
  func validationAndRegistration() async throws {
    let fixture = try ContractFixture.make()
    let (client, collectors) = TelemetryClient.test(policy: fixture.policy)
    let invalid = try fixture.payload(result: "error")

    #expect(throws: TelemetryContractError.invalidPayload(field: nil)) {
      try client.record(fixture.failedLog, payload: invalid)
    }
    #expect(collectors.logs.allRecords.isEmpty)

    let unregistered = try TelemetryLogDefinition<ContractSignalPayload>(
      eventName: .init("contract.unregistered"),
      severity: .info,
      fields: []
    )
    #expect(throws: TelemetryContractError.unregisteredDefinition) {
      try client.record(unregistered, payload: try fixture.payload())
    }

    struct EmptyResource: Sendable {}
    let otherDefinition = try TelemetryResourceDefinition<EmptyResource>(
      name: .init("contract.other-resource"),
      fields: []
    )
    let configuration = TelemetryRuntime.Configuration(
      serviceName: "test-suite",
      endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
      policy: fixture.policy,
      resource: try otherDefinition.makeValue(EmptyResource())
    )
    #expect(throws: TelemetryRuntimeConfigurationError.invalidResourceContract) {
      _ = try TelemetryRuntime(
        configuration: configuration,
        transport: InMemoryEncodedRequestCollector().transport,
        authenticator: .none
      )
    }
  }

  @Test("rejects unbounded counter dimensions and privacy-unsafe raw records")
  func cardinalityAndPrivacyBoundary() throws {
    #expect(throws: TelemetryContractError.invalidValue) {
      _ = try TelemetryStringValue("https://secret.example")
    }
    #expect(throws: TelemetryContractError.invalidName) {
      _ = try TelemetryContractName("Invalid.Name")
    }
    #expect(throws: TelemetryContractError.invalidValue) {
      _ = try TelemetryCounterDelta(0)
    }
    #expect(throws: TelemetryContractError.invalidDefinition) {
      _ = try TelemetryCounterDefinition<ContractResourcePayload>(
        name: .init("contract.unbounded"),
        unit: .init("{event}"),
        description: .init("unbounded-counter"),
        maximumSeries: 4,
        fields: [
          try .string(.init("contract.value")) { $0.namespace }
        ]
      )
    }

    let fixture = try ContractFixture.make()
    let collector = InMemorySpanCollector()
    let exporter = PrivacyPreservingSpanExporter(exporter: collector, policy: fixture.policy)
    let provider = TracerProviderBuilder()
      .add(spanProcessor: SimpleSpanProcessor(spanExporter: exporter))
      .build()
    let tracer = provider.get(
      instrumentationName: ComposableOTelMetadata.instrumentationName,
      instrumentationVersion: ComposableOTelMetadata.version
    )
    let span = tracer.spanBuilder(spanName: fixture.span.name.rawValue)
      .setAttribute(key: "contract.secret", value: "secret")
      .startSpan()
    span.end()
    let invalidConditional = tracer.spanBuilder(spanName: fixture.span.name.rawValue)
      .setAttributes([
        TelemetryContractCatalog.contractVersionKey: .int(7),
        "contract.flow": .string("checkout"),
        "contract.phase": .string("end"),
        "contract.result": .string("error"),
        "contract.retryable": .bool(false),
        "contract.attempt": .int(1),
      ])
      .startSpan()
    invalidConditional.end()
    provider.forceFlush()

    #expect(collector.spans.isEmpty)

    let logCollector = InMemoryLogCollector()
    let logExporter = PrivacyPreservingLogRecordExporter(
      exporter: logCollector,
      policy: fixture.policy
    )
    _ = logExporter.export(
      logRecords: [
        ReadableLogRecord(
          resource: Resource(attributes: [:]),
          instrumentationScopeInfo: InstrumentationScopeInfo(
            name: ComposableOTelMetadata.instrumentationName,
            version: ComposableOTelMetadata.version
          ),
          timestamp: Date(),
          severity: .info,
          body: .string("not-allowed"),
          attributes: [:],
          eventName: fixture.startedLog.eventName.rawValue
        )
      ],
      explicitTimeout: nil
    )
    #expect(logCollector.allRecords.isEmpty)

    let payload = try fixture.payload()
    _ = logExporter.export(
      logRecords: [
        ReadableLogRecord(
          resource: Resource(attributes: [:]),
          instrumentationScopeInfo: InstrumentationScopeInfo(name: "unsafe-scope"),
          timestamp: Date(),
          severity: .info,
          body: nil,
          attributes: try fixture.startedLog.attributes(
            for: payload,
            version: fixture.policy.catalog.contractVersion
          ),
          eventName: fixture.startedLog.eventName.rawValue
        )
      ],
      explicitTimeout: nil
    )
    #expect(logCollector.allRecords.isEmpty)
  }
}
