import ComposableOTelTesting
import Dependencies
import Foundation
import OpenTelemetryApi
import OpenTelemetryProtocolExporterCommon
import OpenTelemetrySdk
import SwiftProtobuf
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

#if canImport(Compression)
  import Compression
#endif

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
  let environment: TelemetryEnumValue
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
    let environmentKey = try TelemetryFieldKey("deployment.environment.name")
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
          environmentKey,
          allowedValues: [
            try .init("development"), try .init("test"), try .init("staging"),
            try .init("production"),
          ]
        ) { $0.environment },
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
        environment: .init("staging")
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
  func deploymentEnvironments() throws {
    for environment in TelemetryDeploymentEnvironment.allCases {
      let resource = try TelemetryBootstrap.makeResource(
        serviceName: "test-suite",
        serviceVersion: nil,
        resourceMode: .native(environment: environment),
        policy: testPolicy()
      )
      #expect(
        resource.attributes["deployment.environment.name"]
          == .string(environment.rawValue)
      )
    }
  }

  private struct DecodedTraceSpan {
    let name: String
    let droppedAttributesCount: UInt64
    let droppedEventsCount: UInt64
    let droppedLinksCount: UInt64
  }

  private enum ProtobufTestError: Error {
    case malformed
    case unsupportedCompression
  }

  private func decodeTraceSpans(_ data: Data) throws -> [DecodedTraceSpan] {
    let request = try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(
      serializedBytes: data
    )
    let json = try request.jsonUTF8Data()
    #expect(
      try Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest(
        jsonUTF8Data: json
      ) == request
    )
    return request.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans).map {
      DecodedTraceSpan(
        name: $0.name,
        droppedAttributesCount: UInt64($0.droppedAttributesCount),
        droppedEventsCount: UInt64($0.droppedEventsCount),
        droppedLinksCount: UInt64($0.droppedLinksCount)
      )
    }
  }

  private func decodedOTLPBody(_ data: Data) throws -> Data {
    guard data.starts(with: [0x1f, 0x8b]) else { return data }
    #if canImport(Compression)
      guard data.count >= 18 else { throw ProtobufTestError.malformed }
      let expectedSize = data.suffix(4).enumerated().reduce(UInt32(0)) { result, element in
        result | (UInt32(element.element) << UInt32(element.offset * 8))
      }
      var output = [UInt8](repeating: 0, count: Int(expectedSize))
      let compressed = data.dropFirst(10).dropLast(8)
      let decodedSize = output.withUnsafeMutableBytes { destination in
        compressed.withUnsafeBytes { source in
          compression_decode_buffer(
            destination.bindMemory(to: UInt8.self).baseAddress!,
            destination.count,
            source.bindMemory(to: UInt8.self).baseAddress!,
            source.count,
            nil,
            COMPRESSION_ZLIB
          )
        }
      }
      guard decodedSize == output.count else { throw ProtobufTestError.malformed }
      return Data(output)
    #else
      throw ProtobufTestError.unsupportedCompression
    #endif
  }

  private func occurrenceCount(in data: Data, of needle: Data) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = data.startIndex..<data.endIndex
    while let range = data.range(of: needle, options: [], in: searchRange) {
      count += 1
      searchRange = range.upperBound..<data.endIndex
    }
    return count
  }

  @Test("strict resources require one bounded deployment environment")
  func strictResourceEnvironment() throws {
    struct ResourcePayload: Sendable {
      let environment: TelemetryStringValue
    }
    let environmentKey = try TelemetryFieldKey("deployment.environment.name")
    let resource = try TelemetryResourceDefinition<ResourcePayload>(
      name: .init("contract.environment"),
      fields: [
        try .string(environmentKey) { $0.environment }
      ]
    )

    #expect(
      throws: TelemetryContractError.invalidPayload(field: environmentKey)
    ) {
      _ = try resource.makeValue(.init(environment: .init("qa")))
    }

    let missingEnvironment = try TelemetryResourceDefinition<Void>(
      name: .init("contract.missing-environment"),
      fields: []
    )
    #expect(throws: TelemetryContractError.invalidDefinition) {
      _ = try TelemetryContractCatalog(
        contractVersion: .init(1),
        resources: [.init(missingEnvironment)]
      )
    }
  }

  @Test("registration identity cannot be reconstructed from an identical definition")
  func canonicalRegistrationIdentity() async throws {
    let registered = try ContractFixture.make()
    let reconstructed = try ContractFixture.make()
    let (client, _) = try TelemetryClient.test(policy: registered.policy)
    let payload = try reconstructed.payload()

    await #expect(throws: TelemetryContractError.unregisteredDefinition) {
      try await client.withSpan(reconstructed.span, payload: payload) { true }
    }
    #expect(throws: TelemetryContractError.unregisteredDefinition) {
      try client.record(reconstructed.startedLog, payload: payload)
    }
    #expect(throws: TelemetryContractError.unregisteredDefinition) {
      try client.add(reconstructed.counter, delta: .init(1), payload: payload)
    }
  }

  @Test("custom catalog definitions cannot reuse native signal names")
  func nativeNamesAreReserved() throws {
    let span = try TelemetrySpanDefinition<Void>(
      name: .init(ComposableOTelSemantics.Spans.reducer),
      fields: []
    )
    let log = try TelemetryLogDefinition<Void>(
      eventName: .init(ComposableOTelSemantics.Events.effectStarted),
      severity: .info,
      bodyPolicy: .none,
      fields: []
    )
    let applicationLog = try TelemetryLogDefinition<Void>(
      eventName: .init(ComposableOTelSemantics.Events.applicationLog),
      severity: .info,
      bodyPolicy: .none,
      fields: []
    )
    let counter = try TelemetryCounterDefinition<Void>(
      name: .init(ComposableOTelSemantics.Metrics.actionsDispatched),
      unit: .init("{event}"),
      description: .init("reserved-name"),
      maximumSeries: 1,
      fields: []
    )

    #expect(throws: TelemetryContractError.invalidDefinition) {
      _ = try TelemetryContractCatalog(
        contractVersion: .init(1),
        spans: [.init(span)]
      )
    }
    #expect(throws: TelemetryContractError.invalidDefinition) {
      _ = try TelemetryContractCatalog(
        contractVersion: .init(1),
        logs: [.init(log)]
      )
    }
    #expect(throws: TelemetryContractError.invalidDefinition) {
      _ = try TelemetryContractCatalog(
        contractVersion: .init(1),
        logs: [.init(applicationLog)]
      )
    }
    #expect(throws: TelemetryContractError.invalidDefinition) {
      _ = try TelemetryContractCatalog(
        contractVersion: .init(1),
        counters: [.init(counter)]
      )
    }
  }

  @Test("disabled and no-op clients preserve sync and async operation semantics")
  func noopSemantics() async throws {
    let fixture = try ContractFixture.make()
    let payload = try fixture.payload()

    let asynchronous = try await TelemetryClient.noop.withSpan(
      fixture.span,
      payload: payload
    ) {
      "async-result"
    }
    let synchronous = try TelemetryClient.noop.withSynchronousSpan(
      fixture.span,
      payload: payload
    ) {
      "sync-result"
    }
    try TelemetryClient.noop.record(fixture.startedLog, payload: payload)
    try TelemetryClient.noop.add(fixture.counter, delta: .init(1), payload: payload)

    #expect(asynchronous == "async-result")
    #expect(synchronous == "sync-result")
  }

  @Test("metric point batches enforce the configured point cap")
  func metricPointBatches() {
    let bounded = runtimePointBoundedBatches(
      [20, 30, 1, 51, 49],
      maximumPoints: 50,
      pointCount: { $0 }
    )

    #expect(bounded.batches == [[20, 30], [1, 49]])
    #expect(bounded.batches.allSatisfy { $0.reduce(0, +) <= 50 })
    #expect(bounded.droppedPoints == 51)

    let diagnostics = RuntimeDiagnosticsState(handler: nil)
    diagnostics.recordMetricPointLimitExceeded(count: bounded.droppedPoints)
    #expect(diagnostics.snapshot().metrics.droppedItems == 51)
  }

  @Test("decoded captures reject mismatched severity and extra resource keys")
  func decodedCapturesValidateActualWireData() {
    #expect(decodedContractLogSeverity(.info) == .info)
    #expect(decodedContractLogSeverity(.error) == .error)
    #expect(decodedContractLogSeverity(.warn) == nil)

    let expectedKeys: Set<String> = ["service.namespace"]
    let exact: [String: AttributeValue] = [
      "service.namespace": .string("sample-app"),
      TelemetryContractCatalog.contractVersionKey: .int(7),
    ]
    #expect(
      decodeContractResourceAttributes(exact, expectedFieldKeys: expectedKeys)?.version == 7
    )

    var withExtra = exact
    withExtra["telemetry.sdk.name"] = .string("opentelemetry")
    #expect(
      decodeContractResourceAttributes(withExtra, expectedFieldKeys: expectedKeys) == nil
    )
  }

  @Test("emits exact typed resource, span, bodyless logs, and delta counter")
  func exactWireContracts() async throws {
    let fixture = try ContractFixture.make()
    let (client, collectors) = try TelemetryClient.test(
      resourceMode: .strict(fixture.resourceValue),
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
    #expect(rawSpan.instrumentationScope.schemaUrl == nil)
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
    #expect(
      collectors.logs.allRecords
        .filter { $0.eventName?.hasPrefix("contract.flow.") == true }
        .allSatisfy { $0.instrumentationScopeInfo.schemaUrl == nil }
    )

    let counter = try #require(collectors.decodedCounters(for: fixture.counter).first)
    #expect(counter.unit == "{event}")
    #expect(counter.isMonotonic)
    #expect(counter.temporality == .delta)
    #expect(counter.value == 3)
    #expect(counter.contractVersion == 7)
    #expect(counter.fields.count == 2)
    #expect(
      collectors.contractMetrics?.metrics(named: fixture.counter.name.rawValue)
        .allSatisfy { $0.instrumentationScopeInfo.schemaUrl == nil } == true
    )

    let resource = try #require(collectors.decodedResource(for: fixture.resource))
    #expect(resource.contractVersion == 7)
    #expect(resource.fields.count == 8)
    #expect(resource.fields["app.build"] == .integer(42))
    #expect(rawSpan.resource.attributes["deployment.environment.name"] == .string("staging"))
    #expect(rawSpan.resource.attributes.count == 9)
    #expect(rawSpan.resource.attributes["telemetry.sdk.name"] == nil)
    #expect(rawSpan.resource.attributes["telemetry.distro.name"] == nil)
  }

  @Test("custom spans preserve error and cancellation outcomes")
  func spanOutcomes() async throws {
    enum ExpectedFailure: Error {
      case failed
    }

    let fixture = try ContractFixture.make()
    let (client, collectors) = try TelemetryClient.test(policy: fixture.policy)
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

  @Test("caught errors use a typed log without reclassifying successful work")
  func handledErrorLog() async throws {
    enum HandledFailure: Error {
      case failed
    }
    let fixture = try ContractFixture.make()
    let (client, collectors) = try TelemetryClient.test(policy: fixture.policy)
    let success = try fixture.payload()
    let failure = try fixture.payload(result: "error", errorCode: "unavailable")

    try await client.withSpan(fixture.span, payload: success) {
      do {
        throw HandledFailure.failed
      } catch {
        try client.record(fixture.failedLog, payload: failure)
      }
    }
    collectors.forceFlush()

    let span = try #require(
      collectors.spans.spans(named: fixture.span.name.rawValue).first
    )
    #expect(span.status == .ok)
    let log = try #require(collectors.decodedLogs(for: fixture.failedLog).first)
    #expect(log.severity == .error)
    #expect(log.body == nil)
    #expect(log.fields["contract.result"] == .string("error"))
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
      resourceMode: .strict(fixture.resourceValue),
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

  @Test("production protobuf preserves dropped counts while adding host context")
  func productionEncodingCountInvariant() async throws {
    let fixture = try ContractFixture.make()
    let capture = InMemoryEncodedRequestCollector()
    let hostContext = TelemetryHostContext(
      processSessionID: .init(
        UUID(uuidString: "c50c7f17-8cd6-4bcb-932e-a0571f382c86")!
      ),
      platform: .macOS,
      processKind: .test
    )
    let policy = TelemetryPolicy(
      schema: fixture.policy.schema,
      catalog: fixture.policy.catalog,
      signals: fixture.policy.signals,
      hostContext: hostContext
    )
    var configuration = TelemetryRuntime.Configuration(
      serviceName: "test-suite",
      endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
      samplingRatio: 1,
      policy: policy,
      resourceMode: .strict(fixture.resourceValue),
      traces: .init(maximumQueueSize: 8, maximumBatchSize: 8),
      logs: .init(maximumQueueSize: 8, maximumBatchSize: 8),
      metricExportInterval: .seconds(3_600)
    )
    configuration.metricExemplars = .traceContext(maximumPerDataPoint: .one)
    let runtime = try TelemetryRuntime(
      configuration: configuration,
      transport: capture.transport,
      authenticator: .none
    )

    let packageAttributes: [String: AttributeValue] = [
      TCAAttributes.featureName: .string("counter"),
      TCAAttributes.actionName: .string("increment"),
      TCAAttributes.effectName: .string("success"),
      TCAAttributes.dependencyName: .string("cache"),
      TCAAttributes.operationName: .string("load"),
      TCAAttributes.navigationRoute: .string("settings"),
      TCAAttributes.errorType: .string("test-error"),
      TCAAttributes.errorCategory: .string("internal"),
      TCAAttributes.errorCode: .string("failed"),
      TCAAttributes.effectOutcome: .string(TelemetryOutcome.success.rawValue),
      TCAAttributes.navigationOperation: .string(NavigationOperation.push.rawValue),
      TCAAttributes.stateChanged: .bool(true),
      TCAAttributes.effectCancelled: .bool(false),
      TCAAttributes.effectLongLived: .bool(false),
      TCAAttributes.effectMarker: .bool(true),
      TCAAttributes.dependencyError: .bool(false),
      TCAAttributes.errorHandled: .bool(true),
    ]
    let invalidLinkContext = SpanContext.create(
      traceId: .invalid,
      spanId: .invalid,
      traceFlags: TraceFlags(),
      traceState: TraceState()
    )
    let packageSpan = runtime.client.tracer
      .spanBuilder(spanName: ComposableOTelSemantics.Spans.effect)
      .addLink(spanContext: invalidLinkContext)
      .startSpan()
    for (key, value) in packageAttributes {
      packageSpan.setAttribute(key: key, value: value)
    }
    for _ in 0..<6 {
      packageSpan.addEvent(name: ComposableOTelSemantics.Events.effectStarted)
    }
    packageSpan.end()

    let payload = try fixture.payload()
    try await runtime.client.withSpan(fixture.span, payload: payload) {
      try runtime.client.record(fixture.startedLog, payload: payload)
      try runtime.client.add(fixture.counter, delta: .init(1), payload: payload)
    }

    let result = await runtime.forceFlush(timeout: .seconds(2))

    #expect(result.succeeded)
    let requests = capture.requests
    #expect(Set(requests.compactMap(\.signal)) == [.traces, .metrics, .logs])
    #expect(requests.allSatisfy { $0.contentType == "application/x-protobuf" })

    let traceBodies = try requests.filter { $0.signal == .traces }.map {
      try decodedOTLPBody($0.body)
    }
    let spans = try traceBodies.flatMap(decodeTraceSpans)
    let packageEncodedSpan = try #require(
      spans.first { $0.name == ComposableOTelSemantics.Spans.effect }
    )
    #expect(packageEncodedSpan.droppedAttributesCount == 1)
    #expect(packageEncodedSpan.droppedEventsCount == 2)
    #expect(packageEncodedSpan.droppedLinksCount == 1)
    let contractEncodedSpan = try #require(
      spans.first { $0.name == fixture.span.name.rawValue }
    )
    #expect(contractEncodedSpan.droppedAttributesCount == 0)
    #expect(contractEncodedSpan.droppedEventsCount == 0)
    #expect(contractEncodedSpan.droppedLinksCount == 0)

    let hostKeys = [
      TCAAttributes.processSessionID,
      TCAAttributes.hostPlatform,
      TCAAttributes.hostProcessKind,
    ]
    for key in hostKeys {
      #expect(
        traceBodies.reduce(0) { $0 + occurrenceCount(in: $1, of: Data(key.utf8)) }
          == spans.count
      )
    }

    let logBodies = try requests.filter { $0.signal == .logs }.map {
      try decodedOTLPBody($0.body)
    }
    for key in hostKeys {
      #expect(
        logBodies.reduce(0) { $0 + occurrenceCount(in: $1, of: Data(key.utf8)) } == 1
      )
    }

    let metricBodies = try requests.filter { $0.signal == .metrics }.map {
      try decodedOTLPBody($0.body)
    }
    let metricRequests = try metricBodies.map {
      try Opentelemetry_Proto_Collector_Metrics_V1_ExportMetricsServiceRequest(
        serializedBytes: $0
      )
    }
    let metrics = metricRequests.flatMap(\.resourceMetrics).flatMap(\.scopeMetrics)
      .flatMap(\.metrics)
    let counter = try #require(metrics.first { $0.name == fixture.counter.name.rawValue })
    let exemplars = counter.sum.dataPoints.flatMap(\.exemplars)
    #expect(!exemplars.isEmpty)
    #expect(exemplars.allSatisfy { $0.filteredAttributes.isEmpty })
    for key in hostKeys {
      #expect(metricBodies.allSatisfy { !$0.contains(Data(key.utf8)) })
    }

    _ = await runtime.shutdown(timeout: .seconds(1))
  }

  @Test("malformed span totals normalize and JSON round-trip without underflow")
  func malformedSpanTotals() throws {
    let collector = InMemorySpanCollector()
    let provider = TracerProviderBuilder()
      .add(spanProcessor: SimpleSpanProcessor(spanExporter: collector))
      .build()
    let tracer = provider.get(
      instrumentationName: ComposableOTelMetadata.instrumentationName,
      instrumentationVersion: ComposableOTelMetadata.version
    )
    let sourceSpan = tracer.spanBuilder(spanName: ComposableOTelSemantics.Spans.effect)
      .setAttribute(key: TCAAttributes.effectName, value: "success")
      .startSpan()
    sourceSpan.addEvent(name: ComposableOTelSemantics.Events.effectStarted)
    sourceSpan.end()
    provider.forceFlush()

    var malformed = try #require(collector.spans.first)
    malformed.settingLinks([
      SpanData.Link(
        context: .create(
          traceId: .invalid,
          spanId: .invalid,
          traceFlags: TraceFlags(),
          traceState: TraceState()
        )
      )
    ])
    malformed.settingTotalAttributeCount(0)
    malformed.settingTotalRecordedEvents(-1)
    malformed.settingTotalRecordedLinks(Int.min)
    let hostContext = TelemetryHostContext(
      processSessionID: .init(
        UUID(uuidString: "c50c7f17-8cd6-4bcb-932e-a0571f382c86")!
      ),
      platform: .macOS,
      processKind: .test
    )
    let boundary = TelemetryPrivacyBoundary(
      policy: TelemetryPolicy(
        schema: testSchema,
        signals: .init(tracesEnabled: true, metricsEnabled: false, logsEnabled: false),
        hostContext: hostContext
      )
    )

    let normalized = try #require(boundary.sanitizedSpans([malformed]).first)
    #expect(normalized.totalAttributeCount == normalized.attributes.count)
    #expect(normalized.totalRecordedEvents == normalized.events.count)
    #expect(normalized.totalRecordedLinks == normalized.links.count)
    #expect(normalized.totalAttributeCount >= normalized.attributes.count)
    #expect(normalized.totalRecordedEvents >= normalized.events.count)
    #expect(normalized.totalRecordedLinks >= normalized.links.count)

    let json = try JSONEncoder().encode(normalized)
    let roundTripped = try JSONDecoder().decode(SpanData.self, from: json)
    #expect(roundTripped == normalized)
    let resanitized = try #require(boundary.sanitizedSpans([roundTripped]).first)
    #expect(resanitized.totalAttributeCount >= resanitized.attributes.count)
    #expect(resanitized.totalRecordedEvents >= resanitized.events.count)
    #expect(resanitized.totalRecordedLinks >= resanitized.links.count)

    var overflowing = malformed
    overflowing.settingTotalAttributeCount(Int.max)
    #expect(boundary.sanitizedSpans([overflowing]).isEmpty)
  }

  @Test("tail-promoted production protobuf preserves dropped counts and host context")
  func tailPromotedProductionEncodingCountInvariant() async throws {
    enum ExpectedFailure: Error {
      case failed
    }

    let fixture = try ContractFixture.make()
    let capture = InMemoryEncodedRequestCollector()
    let hostContext = TelemetryHostContext(
      processSessionID: .init(
        UUID(uuidString: "c50c7f17-8cd6-4bcb-932e-a0571f382c86")!
      ),
      platform: .macOS,
      processKind: .test
    )
    let policy = TelemetryPolicy(
      schema: fixture.policy.schema,
      catalog: fixture.policy.catalog,
      signals: fixture.policy.signals,
      hostContext: hostContext
    )
    var configuration = TelemetryRuntime.Configuration(
      serviceName: "test-suite",
      endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
      samplingRatio: 0,
      policy: policy,
      resourceMode: .strict(fixture.resourceValue),
      traces: .init(maximumQueueSize: 128, maximumBatchSize: 16),
      logs: .init(maximumQueueSize: 64, maximumBatchSize: 16),
      metricExportInterval: .seconds(3_600)
    )
    configuration.tailSampling = .enabled(
      try TelemetryTailSamplingPolicy(
        slowTraceThreshold: .seconds(1),
        maximumTraceCount: 64,
        maximumRetainedSpanCount: 128,
        maximumRetainedBreadcrumbCount: 64,
        maximumRetainedBytes: 512 * 1_024,
        maximumAge: .seconds(2)
      )
    )
    let runtime = try TelemetryRuntime(
      configuration: configuration,
      transport: capture.transport,
      authenticator: .none
    )

    let overflowAttributes: [String: AttributeValue] = [
      TCAAttributes.featureName: .string("counter"),
      TCAAttributes.actionName: .string("increment"),
      TCAAttributes.effectName: .string("failure"),
      TCAAttributes.dependencyName: .string("cache"),
      TCAAttributes.operationName: .string("load"),
      TCAAttributes.navigationRoute: .string("settings"),
      TCAAttributes.errorType: .string("test-error"),
      TCAAttributes.errorCategory: .string("internal"),
      TCAAttributes.errorCode: .string("failed"),
      TCAAttributes.effectOutcome: .string(TelemetryOutcome.error.rawValue),
      TCAAttributes.navigationOperation: .string(NavigationOperation.push.rawValue),
      TCAAttributes.stateChanged: .bool(true),
      TCAAttributes.effectCancelled: .bool(false),
      TCAAttributes.effectLongLived: .bool(false),
      TCAAttributes.effectMarker: .bool(true),
      TCAAttributes.dependencyError: .bool(false),
      TCAAttributes.errorHandled: .bool(true),
    ]
    let invalidLinkContext = SpanContext.create(
      traceId: .invalid,
      spanId: .invalid,
      traceFlags: TraceFlags(),
      traceState: TraceState()
    )

    do {
      let _: Void = try await runtime.client.withEffectTrace(
        effect: "failure",
        longLived: false,
        parentContext: nil
      ) {
        let parentContext = try #require(ReducerTraceContext.spanContext)
        let overflowSpan = runtime.client.tracer
          .spanBuilder(spanName: ComposableOTelSemantics.Spans.effect)
          .setParent(parentContext)
          .addLink(spanContext: invalidLinkContext)
          .startSpan()
        for (key, value) in overflowAttributes {
          overflowSpan.setAttribute(key: key, value: value)
        }
        for _ in 0..<6 {
          overflowSpan.addEvent(name: ComposableOTelSemantics.Events.effectStarted)
        }
        overflowSpan.end()
        #expect(runtime.client.log(.info, "Breadcrumb before promotion") == .recorded)
        throw ExpectedFailure.failed
      }
      Issue.record("Expected failure")
    } catch is ExpectedFailure {
    }

    let result = await runtime.forceFlush(timeout: .seconds(2))

    #expect(result.traces.status == .success)
    #expect(result.logs.status == .success)
    #expect(runtime.tailSamplingSnapshot?.retainedSpanCount == 0)
    #expect(runtime.tailSamplingSnapshot?.retainedBreadcrumbCount == 0)

    let requests = capture.requests
    #expect(Set(requests.compactMap(\.signal)).contains(.traces))
    #expect(requests.allSatisfy { $0.contentType == "application/x-protobuf" })

    let traceBodies = try requests.filter { $0.signal == .traces }.map {
      try decodedOTLPBody($0.body)
    }
    let spans = try traceBodies.flatMap(decodeTraceSpans)
    let overflowEncodedSpan = try #require(
      spans.first { $0.name == ComposableOTelSemantics.Spans.effect }
    )
    #expect(overflowEncodedSpan.droppedAttributesCount == 1)
    #expect(overflowEncodedSpan.droppedEventsCount == 2)
    #expect(overflowEncodedSpan.droppedLinksCount == 1)

    let hostKeys = [
      TCAAttributes.processSessionID,
      TCAAttributes.hostPlatform,
      TCAAttributes.hostProcessKind,
    ]
    for key in hostKeys {
      #expect(
        traceBodies.reduce(0) { $0 + occurrenceCount(in: $1, of: Data(key.utf8)) }
          == spans.count
      )
    }

    let logBodies = try requests.filter { $0.signal == .logs }.map {
      try decodedOTLPBody($0.body)
    }
    let logRecordCount =
      try logBodies
      .map {
        try Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest(serializedBytes: $0)
      }
      .flatMap(\.resourceLogs).flatMap(\.scopeLogs).flatMap(\.logRecords).count
    #expect(logRecordCount == 2)
    for key in hostKeys {
      #expect(
        logBodies.reduce(0) { $0 + occurrenceCount(in: $1, of: Data(key.utf8)) }
          == logRecordCount
      )
    }

    _ = await runtime.shutdown(timeout: .seconds(1))
  }

  @Test("one observer metric lifecycle covers native and delta contract readers")
  func observerMetricLifecycle() async throws {
    let fixture = try ContractFixture.make()
    let capture = InMemoryEncodedRequestCollector()
    let observer = ObserverMetricExporter()
    let configuration = TelemetryRuntime.Configuration(
      serviceName: "test-suite",
      endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
      samplingRatio: 1,
      policy: fixture.policy,
      resourceMode: .strict(fixture.resourceValue),
      traces: .init(maximumQueueSize: 1, maximumBatchSize: 1),
      logs: .init(maximumQueueSize: 1, maximumBatchSize: 1),
      metricExportInterval: .seconds(3_600),
      observerExporters: .init(metricExporters: [observer])
    )
    let runtime = try TelemetryRuntime(
      configuration: configuration,
      transport: capture.transport,
      authenticator: .none
    )
    let payload = try fixture.payload()

    runtime.client.recordNavigation(.push, route: "settings")
    try runtime.client.add(fixture.counter, delta: .init(1), payload: payload)
    let result = await runtime.shutdown(timeout: .seconds(2))

    #expect(result.succeeded)
    let native = try #require(
      observer.metrics.first {
        $0.name == ComposableOTelSemantics.Metrics.navigationTransitions
      }
    )
    #expect(native.data.aggregationTemporality == .cumulative)
    let contract = try #require(
      observer.metrics.first { $0.name == fixture.counter.name.rawValue }
    )
    #expect(contract.data.aggregationTemporality == .delta)
    #expect(observer.flushCount == 1)
    #expect(observer.shutdownCount == 1)
  }

  @Test("rejects invalid conditional payloads and unregistered definitions")
  func validationAndRegistration() async throws {
    let fixture = try ContractFixture.make()
    let (client, collectors) = try TelemetryClient.test(policy: fixture.policy)
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

    let reconstructedResource = try ContractFixture.make().resourceValue
    #expect(throws: TelemetryContractError.unregisteredDefinition) {
      _ = try TelemetryBootstrap.makeResource(
        serviceName: "test-suite",
        serviceVersion: nil,
        resourceMode: .strict(reconstructedResource),
        policy: fixture.policy
      )
    }
    #expect(throws: TelemetryContractError.unregisteredDefinition) {
      _ = try TelemetryClient.test(
        resourceMode: .strict(reconstructedResource),
        policy: fixture.policy
      )
    }
    let configuration = TelemetryRuntime.Configuration(
      serviceName: "test-suite",
      endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
      policy: fixture.policy,
      resourceMode: .strict(reconstructedResource)
    )
    #expect(throws: TelemetryRuntimeConfigurationError.invalidResourceContract) {
      _ = try TelemetryRuntime(
        configuration: configuration,
        transport: InMemoryEncodedRequestCollector().transport,
        authenticator: .none
      )
    }

    struct MetricPayload: Sendable {
      let point: Int64
    }
    let pointField = try TelemetryField<MetricPayload>.integer(
      .init("contract.point"),
      range: 0...50
    ) { $0.point }
    let oversizedCounter = try TelemetryCounterDefinition(
      name: TelemetryContractName("contract.too-many-points"),
      unit: TelemetryStringValue("{event}"),
      description: TelemetryStringValue("too-many-points"),
      maximumSeries: 51,
      fields: [pointField]
    )
    let oversizedCatalog = try TelemetryContractCatalog(
      contractVersion: .init(1),
      counters: [.init(oversizedCounter)]
    )
    var metricConfiguration = TelemetryRuntime.Configuration(
      serviceName: "test-suite",
      endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
      policy: TelemetryPolicy(catalog: oversizedCatalog)
    )
    metricConfiguration.delivery.maximumContractMetricPointsPerRequest = 50
    #expect(throws: TelemetryRuntimeConfigurationError.invalidDeliveryLimits) {
      _ = try TelemetryRuntime(
        configuration: metricConfiguration,
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
