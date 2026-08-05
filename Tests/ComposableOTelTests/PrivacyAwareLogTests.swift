import ComposableOTelTesting
import Compression
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import Testing

@testable import ComposableOTel
@testable import ComposableOTelExporters

@Suite("Privacy-aware interpolated logs", .serialized)
struct PrivacyAwareLogTests {
  @Test("redacts private values before collection and preserves stable template identity")
  func defaultRedactionAndTemplateIdentity() throws {
    let policy = try logPolicy()
    let (client, collectors) = try TelemetryClient.test(policy: policy)
    let firstSecret = "private-plan-123"
    let secondSecret = "different-plan-456"

    #expect(
      client.log(
        .info,
        "Plan \(firstSecret) save finished with \(TelemetryOutcome.success, privacy: .public)"
      ) == .recorded
    )
    #expect(
      client.log(
        .info,
        "Plan \(secondSecret) save finished with \(TelemetryOutcome.error, privacy: .public)"
      ) == .recorded
    )

    let logs = collectors.logs.privacyAwareLogs
    #expect(logs.count == 2)
    #expect(
      logs.map(\.template)
        == [
          "Plan <private> save finished with <public:0:outcome>",
          "Plan <private> save finished with <public:0:outcome>",
        ]
    )
    #expect(logs[0].templateID == logs[1].templateID)
    #expect(logs[0].body == "Plan <private> save finished with success")
    #expect(logs[1].body == "Plan <private> save finished with error")
    #expect(!logs[0].body.contains(firstSecret))
    #expect(!logs[1].body.contains(secondSecret))
    #expect(
      logs[0].publicValues
        == [
          .init(index: 0, kind: .outcome, value: .string("success"))
        ]
    )
  }

  @Test("exports only approved bounded public value types")
  func approvedPublicValues() throws {
    let policy = try logPolicy()
    let (client, collectors) = try TelemetryClient.test(policy: policy)
    let operation: OperationID = "save"
    let correlation = TelemetryCorrelationID(
      UUID(uuidString: "a5f86b75-79e0-4f9f-834f-f076355ef803")!
    )

    #expect(
      client.log(
        .error,
        """
        Result \(operation, privacy: .public) \(true, privacy: .public) \
        \(TelemetryLogInteger(2_000_000), privacy: .public) \
        \(TelemetryLogDuration(milliseconds: -1), privacy: .public) \
        \(TelemetryLogCountBucket(count: 42), privacy: .public) \
        \(correlation, privacy: .public) \
        \(NavigationOperation.push, privacy: .public)
        """
      ) == .recorded
    )

    let log = try #require(collectors.logs.privacyAwareLogs.first)
    #expect(log.severity == .error)
    #expect(
      log.body
        == "Result save true 1000000 0 twenty-one-to-hundred a5f86b75-79e0-4f9f-834f-f076355ef803 push"
    )
    #expect(
      log.publicValues.map(\.kind)
        == [
          .operationID,
          .boolean,
          .integer,
          .durationMilliseconds,
          .countBucket,
          .correlationID,
          .navigationOperation,
        ]
    )
    #expect(
      log.publicValues.map(\.value)
        == [
          .string("save"),
          .boolean(true),
          .integer(1_000_000),
          .integer(0),
          .string("twenty-one-to-hundred"),
          .string("a5f86b75-79e0-4f9f-834f-f076355ef803"),
          .string("push"),
        ]
    )
  }

  @Test("exports every schema-bounded identifier domain")
  func approvedIdentifierDomains() throws {
    let policy = try logPolicy()
    let (client, collectors) = try TelemetryClient.test(policy: policy)
    let feature: FeatureID = "library"
    let action: ActionID = "save-tapped"
    let effect: EffectID = "save-plan"
    let dependency: DependencyID = "plan-client"
    let route: RouteID = "plan-detail"
    let errorType: ErrorTypeID = "save-failure"
    let errorCategory: ErrorCategoryID = "persistence"
    let errorCode: ErrorCodeID = "write-failed"
    let service: ServiceID = "test-suite"
    let serviceVersion: ServiceVersionID = "1.0"

    #expect(
      client.log(
        .info,
        """
        IDs \(feature, privacy: .public) \(action, privacy: .public) \
        \(effect, privacy: .public) \(dependency, privacy: .public) \
        \(route, privacy: .public) \(errorType, privacy: .public) \
        \(errorCategory, privacy: .public) \(errorCode, privacy: .public)
        """
      ) == .recorded
    )
    #expect(
      client.log(
        .info,
        "Service \(service, privacy: .public) \(serviceVersion, privacy: .public)"
      ) == .recorded
    )

    #expect(
      collectors.logs.privacyAwareLogs.flatMap(\.publicValues).map(\.kind)
        == [
          .featureID,
          .actionID,
          .effectID,
          .dependencyID,
          .routeID,
          .errorTypeID,
          .errorCategoryID,
          .errorCodeID,
          .serviceID,
          .serviceVersionID,
        ]
    )
  }

  @Test("count buckets cover every finite range")
  func countBucketRanges() {
    #expect(TelemetryLogCountBucket(count: -1) == .zero)
    #expect(TelemetryLogCountBucket(count: 1) == .one)
    #expect(TelemetryLogCountBucket(count: 2) == .twoToFive)
    #expect(TelemetryLogCountBucket(count: 6) == .sixToTwenty)
    #expect(TelemetryLogCountBucket(count: 21) == .twentyOneToHundred)
    #expect(TelemetryLogCountBucket(count: 101) == .overHundred)
  }

  @Test("schema-bounds public identifiers")
  func boundsPublicIdentifiersThroughPolicy() throws {
    let policy = try logPolicy()
    let (client, collectors) = try TelemetryClient.test(policy: policy)
    let unregistered: OperationID = "delete"

    #expect(client.log(.info, "Operation \(unregistered, privacy: .public)") == .recorded)

    let log = try #require(collectors.logs.privacyAwareLogs.first)
    #expect(log.body == "Operation other")
    #expect(log.publicValues.first?.value == .string("other"))
  }

  @Test("rejects oversized templates and interpolation counts deterministically")
  func rejectsMessageLimits() throws {
    let policy = try logPolicy()
    let (client, collectors) = try TelemetryClient.test(policy: policy)
    var oversizedInterpolation = TelemetryLogMessage.StringInterpolation(
      literalCapacity: TelemetryLogMessage.maximumTemplateUTF8Bytes + 1,
      interpolationCount: 0
    )
    for _ in 0..<9 {
      oversizedInterpolation.appendLiteral(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      )
    }
    let oversized = TelemetryLogMessage(stringInterpolation: oversizedInterpolation)
    let tooManyInterpolations: TelemetryLogMessage =
      "\(0)\(1)\(2)\(3)\(4)\(5)\(6)\(7)\(8)\(9)\(10)\(11)\(12)\(13)\(14)\(15)\(16)"
    let tooManyPublicValues: TelemetryLogMessage =
      """
      \(true, privacy: .public)\(true, privacy: .public)\(true, privacy: .public)\
      \(true, privacy: .public)\(true, privacy: .public)\(true, privacy: .public)\
      \(true, privacy: .public)\(true, privacy: .public)\(true, privacy: .public)
      """

    #expect(client.log(.info, oversized) == .invalidMessage)
    #expect(client.log(.info, tooManyInterpolations) == .invalidMessage)
    #expect(client.log(.info, tooManyPublicValues) == .invalidMessage)
    #expect(collectors.logs.privacyAwareLogs.isEmpty)
  }

  @Test("disabled logs do not evaluate private interpolations")
  func disabledLogsDoNotEvaluatePrivateValues() throws {
    let policy = try logPolicy(logsEnabled: false)
    let (client, collectors) = try TelemetryClient.test(policy: policy)
    let evaluation = EvaluationCounter()

    #expect(client.log(.info, "Value \(evaluation.next())") == .disabled)
    #expect(evaluation.count == 0)
    #expect(collectors.logs.allRecords.isEmpty)
  }

  @Test("sanitizer rebuilds bodies and rejects malformed wire shapes")
  func sanitizerRebuildsAndRejects() throws {
    let policy = try logPolicy()
    let (client, sourceCollectors) = try TelemetryClient.test(policy: policy)
    #expect(
      client.log(.info, "Secret \("sentinel-private-value") \(true, privacy: .public)")
        == .recorded
    )
    let source = try #require(sourceCollectors.logs.allRecords.first)
    let collector = InMemoryLogCollector()
    let exporter = PrivacyPreservingLogRecordExporter(exporter: collector, policy: policy)
    let forgedBody = logRecord(
      source,
      body: .string("sentinel-forged-body"),
      attributes: source.attributes
    )
    var extraAttributes = source.attributes
    extraAttributes["log.private"] = .string("sentinel-extra-value")
    let extraField = logRecord(source, body: source.body, attributes: extraAttributes)
    var badIdentityAttributes = source.attributes
    badIdentityAttributes[TelemetryLogWireFormat.templateIDKey] = .string("0000000000000000")
    let badIdentity = logRecord(source, body: source.body, attributes: badIdentityAttributes)

    _ = exporter.export(
      logRecords: [forgedBody, extraField, badIdentity],
      explicitTimeout: nil
    )

    #expect(collector.allRecords.count == 1)
    #expect(collector.allRecords.first?.body == .string("Secret <private> true"))
    #expect(!String(reflecting: collector.allRecords).contains("sentinel"))
  }

  @Test("test collector preserves active trace correlation")
  func testCollectorTraceCorrelation() throws {
    let policy = try logPolicy()
    let (client, collectors) = try TelemetryClient.test(policy: policy)
    var expectedContext: SpanContext?

    client.tracer.spanBuilder(spanName: "test.log").withActiveSpan { span in
      expectedContext = span.context
      #expect(client.log(.info, "Correlated") == .recorded)
    }

    #expect(collectors.logs.privacyAwareLogs.first?.spanContext == expectedContext)
  }

  @Test("runtime observers, OTLP queue, and persistence receive only sanitized records")
  func runtimeRetainedPathsAreSanitized() async throws {
    let policy = try logPolicy()
    let observer = ObserverLogRecordExporter()
    let transport = InMemoryEncodedRequestCollector()
    let persistenceDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("privacy-aware-log-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: persistenceDirectory)
    }
    let configuration = TelemetryRuntime.Configuration(
      serviceName: "test-suite",
      endpoints: .init(baseURL: URL(string: "https://gateway.example.test/otlp")!),
      samplingRatio: 1,
      policy: policy,
      resourceMode: .native(environment: .test),
      traces: .init(maximumQueueSize: 1, maximumBatchSize: 1),
      logs: .init(maximumQueueSize: 1, maximumBatchSize: 1),
      metricExportInterval: .seconds(3_600),
      persistence: .init(directory: persistenceDirectory),
      observerExporters: .init(logRecordExporters: [observer])
    )
    let runtime = try TelemetryRuntime(
      configuration: configuration,
      transport: transport.transport,
      authenticator: .none
    )
    await runtime.setExportCondition(.unavailable)
    let privateValue = "sentinel-runtime-private"
    var expectedContext: SpanContext?

    runtime.client.tracer.spanBuilder(spanName: "runtime.log").withActiveSpan { span in
      expectedContext = span.context
      #expect(
        runtime.client.log(
          .error,
          "Runtime \(privateValue) \(TelemetryOutcome.success, privacy: .public)"
        ) == .recorded
      )
    }

    #expect(observer.records.count == 1)
    let observed = try #require(observer.records.first)
    #expect(observed.body == .string("Runtime <private> success"))
    #expect(observed.spanContext == expectedContext)
    #expect(!String(reflecting: observed).contains(privateValue))

    _ = await runtime.forceFlush(timeout: .milliseconds(100))
    let persistedBody = try await persistedOTLPBody(in: persistenceDirectory)
    #expect(!String(decoding: persistedBody, as: UTF8.self).contains(privateValue))
    #expect(String(decoding: persistedBody, as: UTF8.self).contains("<private>"))

    let discard = await runtime.disableAndDiscardPending()
    #expect(discard.logs.droppedItems >= 1)
  }
}

private final class EvaluationCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var count: Int {
    lock.withLock { storage }
  }

  func next() -> Int {
    lock.withLock {
      storage += 1
      return storage
    }
  }
}

private func logPolicy(logsEnabled: Bool = true) throws -> TelemetryPolicy {
  TelemetryPolicy(
    schema: try TelemetrySchema(
      features: ["library"],
      actions: ["save-tapped"],
      effects: ["save-plan"],
      dependencies: ["plan-client"],
      operations: ["save"],
      routes: ["plan-detail"],
      errorTypes: ["save-failure"],
      errorCategories: ["persistence"],
      errorCodes: ["write-failed"],
      services: ["test-suite"],
      serviceVersions: ["1.0"]
    ),
    signals: .init(
      tracesEnabled: true,
      metricsEnabled: false,
      logsEnabled: logsEnabled
    )
  )
}

private func logRecord(
  _ source: ReadableLogRecord,
  body: AttributeValue?,
  attributes: [String: AttributeValue]
) -> ReadableLogRecord {
  ReadableLogRecord(
    resource: source.resource,
    instrumentationScopeInfo: source.instrumentationScopeInfo,
    timestamp: source.timestamp,
    observedTimestamp: source.observedTimestamp,
    spanContext: source.spanContext,
    severity: source.severity,
    body: body,
    attributes: attributes,
    eventName: source.eventName
  )
}

private func persistedOTLPBody(in directory: URL) async throws -> Data {
  for _ in 0..<100 {
    let files = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    )
    for file in files {
      let data = try Data(contentsOf: file)
      let object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
      )
      guard object["signal"] as? String == TelemetryRuntimeSignal.logs.rawValue else {
        continue
      }
      let encodedBody = try #require(object["body"] as? String)
      let body = try #require(Data(base64Encoded: encodedBody))
      let headers = try #require(object["headers"] as? [String: String])
      if headers["Content-Encoding"] == "gzip" || headers["content-encoding"] == "gzip" {
        return try gunzip(body)
      }
      return body
    }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Expected a persisted OTLP log batch")
  return Data()
}

private func gunzip(_ data: Data) throws -> Data {
  let minimumGzipSize = 18
  guard data.count >= minimumGzipSize else {
    throw GzipTestError.invalidData
  }
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
  guard decodedSize == output.count else {
    throw GzipTestError.invalidData
  }
  return Data(output)
}

private enum GzipTestError: Error {
  case invalidData
}
