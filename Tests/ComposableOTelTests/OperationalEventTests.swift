import ComposableOTelTesting
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

private struct OperationalEventPayload: Sendable {
  let phase: TelemetryEnumValue
  let attempt: Int64
  let retryable: Bool
}

private struct OperationalEventFixture {
  let definition: TelemetryOperationalEventDefinition<OperationalEventPayload>
  let policy: TelemetryPolicy
  let phaseKey: TelemetryFieldKey
  let attemptKey: TelemetryFieldKey
  let retryableKey: TelemetryFieldKey

  static func make(enabled: Bool = true) throws -> Self {
    let phaseKey = try TelemetryFieldKey("sync.phase")
    let attemptKey = try TelemetryFieldKey("sync.attempt")
    let retryableKey = try TelemetryFieldKey("sync.retryable")
    let definition = try TelemetryOperationalEventDefinition<OperationalEventPayload>(
      eventName: .init("app.operation.event"),
      fields: [
        try .enumeration(
          phaseKey,
          allowedValues: [.init("queued"), .init("started"), .init("completed")]
        ) { $0.phase },
        try .integer(attemptKey, range: 0...3) { $0.attempt },
        .boolean(retryableKey) { $0.retryable },
      ]
    )
    let catalog = try TelemetryContractCatalog(
      contractVersion: .init(1),
      operationalEvents: [.init(definition)]
    )
    return Self(
      definition: definition,
      policy: TelemetryPolicy(
        catalog: catalog,
        signals: .init(
          tracesEnabled: false,
          metricsEnabled: false,
          logsEnabled: false,
          operationalEventsEnabled: enabled
        )
      ),
      phaseKey: phaseKey,
      attemptKey: attemptKey,
      retryableKey: retryableKey
    )
  }

  func payload(_ phase: String, attempt: Int64 = 0) throws -> OperationalEventPayload {
    try OperationalEventPayload(
      phase: .init(phase),
      attempt: attempt,
      retryable: attempt > 0
    )
  }
}

@Suite("Contract-bound operational events", .serialized)
struct OperationalEventTests {
  @Test("accepts registered events synchronously in recording order")
  func acceptsSynchronouslyInOrder() throws {
    let fixture = try OperationalEventFixture.make()
    let (client, collectors) = try TelemetryClient.test(policy: fixture.policy)

    try client.record(fixture.definition, payload: fixture.payload("queued"))
    try client.record(fixture.definition, payload: fixture.payload("started", attempt: 1))
    try client.record(fixture.definition, payload: fixture.payload("completed", attempt: 2))

    let events = collectors.decodedOperationalEvents(for: fixture.definition)
    #expect(events.map(\.eventName) == Array(repeating: "app.operation.event", count: 3))
    #expect(events.map(\.contractVersion) == [1, 1, 1])
    #expect(
      events.map(\.fields)
        == [
          [
            "sync.phase": .string("queued"),
            "sync.attempt": .integer(0),
            "sync.retryable": .boolean(false),
          ],
          [
            "sync.phase": .string("started"),
            "sync.attempt": .integer(1),
            "sync.retryable": .boolean(true),
          ],
          [
            "sync.phase": .string("completed"),
            "sync.attempt": .integer(2),
            "sync.retryable": .boolean(true),
          ],
        ]
    )
  }

  @Test("rejects unknown definitions and invalid finite values")
  func rejectsUnknownDefinitionsAndValues() throws {
    let fixture = try OperationalEventFixture.make()
    let (client, collectors) = try TelemetryClient.test(policy: fixture.policy)
    let unknown = try TelemetryOperationalEventDefinition<OperationalEventPayload>(
      eventName: .init("app.operation.unknown"),
      fields: []
    )

    #expect(throws: TelemetryContractError.unregisteredDefinition) {
      try client.record(unknown, payload: fixture.payload("queued"))
    }
    #expect(throws: TelemetryContractError.invalidPayload(field: fixture.phaseKey)) {
      try client.record(fixture.definition, payload: fixture.payload("unknown"))
    }
    #expect(throws: TelemetryContractError.invalidPayload(field: fixture.attemptKey)) {
      try client.record(fixture.definition, payload: fixture.payload("queued", attempt: 4))
    }
    #expect(collectors.logs.allRecords.isEmpty)
  }

  @Test("rejects missing, extra, unknown, and malformed wire attributes")
  func rejectsInvalidWireShapes() throws {
    let fixture = try OperationalEventFixture.make()
    let collector = InMemoryLogCollector()
    let exporter = PrivacyPreservingLogRecordExporter(
      exporter: collector,
      policy: fixture.policy
    )
    let valid = try fixture.definition.attributes(
      for: fixture.payload("queued"),
      version: fixture.policy.catalog.contractVersion
    )
    var missing = valid
    missing.removeValue(forKey: fixture.attemptKey.rawValue)
    var extra = valid
    extra["sync.secret"] = .string("not-allowed")
    var unknownValue = valid
    unknownValue[fixture.phaseKey.rawValue] = .string("unknown")
    var wrongType = valid
    wrongType[fixture.retryableKey.rawValue] = .string("true")

    _ = exporter.export(
      logRecords: [
        record(name: fixture.definition.eventName.rawValue, attributes: missing),
        record(name: fixture.definition.eventName.rawValue, attributes: extra),
        record(name: fixture.definition.eventName.rawValue, attributes: unknownValue),
        record(name: fixture.definition.eventName.rawValue, attributes: wrongType),
        record(name: "app.operation.unknown", attributes: valid),
      ],
      explicitTimeout: nil
    )

    #expect(collector.allRecords.isEmpty)
  }

  @Test("does not enable package logs and honors disabled operational events")
  func independentEnablement() throws {
    let enabled = try OperationalEventFixture.make()
    let (enabledClient, enabledCollectors) = try TelemetryClient.test(policy: enabled.policy)
    enabledClient.emitLog(
      severity: .error,
      body: ComposableOTelSemantics.LogBodies.effectFailed,
      attributes: [:]
    )
    try enabledClient.record(enabled.definition, payload: enabled.payload("queued"))
    #expect(enabledCollectors.logs.allRecords.count == 1)

    let disabled = try OperationalEventFixture.make(enabled: false)
    let (disabledClient, disabledCollectors) = try TelemetryClient.test(policy: disabled.policy)
    try disabledClient.record(disabled.definition, payload: disabled.payload("queued"))
    #expect(disabledCollectors.logs.allRecords.isEmpty)
  }

  @Test("rejects integer contracts that are not stable on watchOS")
  func rejectsPlatformDependentIntegers() throws {
    #expect(throws: TelemetryContractError.invalidDefinition) {
      _ = try TelemetryField<OperationalEventPayload>.integer(
        .init("sync.unbounded"),
        range: Int64(Int32.min)...(Int64(Int32.max) + 1)
      ) { $0.attempt }
    }
  }

  @Test("uses the bounded runtime queue and deterministic overflow policy")
  func boundedRuntimeOverflow() async throws {
    let fixture = try OperationalEventFixture.make()
    let diagnostics = RuntimeDiagnosticsState(handler: nil)
    let collector = InMemoryLogCollector()
    let exporter = PrivacyPreservingLogRecordExporter(
      exporter: collector,
      policy: fixture.policy
    )
    let firstExportStarted = DispatchSemaphore(value: 0)
    let releaseFirstExport = DispatchSemaphore(value: 0)
    let queue = RuntimeBatchQueue<ReadableLogRecord>(
      configuration: .init(
        maximumQueueSize: 2,
        maximumBatchSize: 2,
        scheduledDelay: .seconds(60),
        overflowPolicy: .dropOldest
      ),
      signal: .logs,
      diagnostics: diagnostics,
      clock: .live,
      export: { records, timeout in
        if records.first?.attributes["sync.attempt"] == .int(0) {
          firstExportStarted.signal()
          _ = releaseFirstExport.wait(timeout: .now() + 10)
        }
        return exporter.export(logRecords: records, explicitTimeout: timeout) == .success
      },
      shutdownExporter: { timeout in
        exporter.shutdown(explicitTimeout: timeout)
      }
    )
    func queuedRecord(_ phase: String, attempt: Int64 = 0) throws -> ReadableLogRecord {
      record(
        name: fixture.definition.eventName.rawValue,
        attributes: try fixture.definition.attributes(
          for: fixture.payload(phase, attempt: attempt),
          version: fixture.policy.catalog.contractVersion
        )
      )
    }

    queue.offer(try queuedRecord("queued"))
    queue.offer(try queuedRecord("started", attempt: 1))
    #expect(await waitForOperationalExport(firstExportStarted) == .success)
    queue.offer(try queuedRecord("completed", attempt: 2))
    queue.offer(try queuedRecord("queued", attempt: 3))
    queue.offer(try queuedRecord("started", attempt: 1))
    releaseFirstExport.signal()
    await queue.forceFlush()

    #expect(diagnostics.snapshot().logs.droppedItems == 1)
    #expect(
      collector.allRecords.compactMap { record -> String? in
        guard case .string(let phase) = record.attributes["sync.phase"] else { return nil }
        return phase
      } == ["queued", "started", "queued", "started"]
    )
    await queue.shutdown()
  }

  @Test("discard stops synchronous acceptance and deletes pending events")
  func discardPending() async throws {
    let fixture = try OperationalEventFixture.make()
    let runtime = try TelemetryRuntime(
      configuration: runtimeConfiguration(
        fixture: fixture,
        logs: .init(
          maximumQueueSize: 4,
          maximumBatchSize: 4,
          scheduledDelay: .seconds(60)
        )
      ),
      transport: InMemoryEncodedRequestCollector().transport,
      authenticator: .none
    )
    try runtime.client.record(fixture.definition, payload: fixture.payload("queued"))
    #expect(runtime.diagnostics.logs.queueDepth == 1)

    let result = await runtime.disableAndDiscardPending()
    #expect(result.logs.droppedItems == 1)
    #expect(runtime.diagnostics.logs.queueDepth == 0)

    try runtime.client.record(fixture.definition, payload: fixture.payload("started"))
    #expect(runtime.diagnostics.logs.queueDepth == 0)
    #expect(runtime.diagnostics.logs.droppedItems == 2)
  }
}

private func record(
  name: String,
  attributes: [String: AttributeValue]
) -> ReadableLogRecord {
  ReadableLogRecord(
    resource: Resource(attributes: [:]),
    instrumentationScopeInfo: InstrumentationScopeInfo(
      name: ComposableOTelMetadata.instrumentationName,
      version: ComposableOTelMetadata.version
    ),
    timestamp: Date(),
    severity: .info,
    body: nil,
    attributes: attributes,
    eventName: name
  )
}

private func runtimeConfiguration(
  fixture: OperationalEventFixture,
  logs: TelemetryBatchConfiguration
) -> TelemetryRuntime.Configuration {
  .init(
    serviceName: "test-suite",
    endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
    policy: fixture.policy,
    traces: .init(scheduledDelay: .seconds(60)),
    logs: logs,
    metricExportInterval: .seconds(3_600)
  )
}

private func waitForOperationalExport(
  _ semaphore: DispatchSemaphore
) async -> DispatchTimeoutResult {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(returning: semaphore.wait(timeout: .now() + 10))
    }
  }
}
