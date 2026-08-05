import ComposableOTel
import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

struct RuntimeHeadSamplingDecision: Sendable {
  let ratio: Double

  func isSampled(traceID: TraceId) -> Bool {
    if ratio <= 0 { return false }
    if ratio >= 1 { return true }
    return traceID.rawLowerLong < UInt(ratio * Double(UInt.max))
  }
}

package final class RuntimeTailRecordingSampler: Sampler, @unchecked Sendable {
  private static let decision = AlwaysRecordingDecision()

  package init() {}

  package var description: String {
    "ComposableOTelTailRecordingSampler"
  }

  package func shouldSample(
    parentContext: SpanContext?,
    traceId: TraceId,
    name: String,
    kind: SpanKind,
    attributes: [String: AttributeValue],
    parentLinks: [SpanData.Link]
  ) -> any Decision {
    Self.decision
  }
}

private struct AlwaysRecordingDecision: Decision, Sendable {
  let isSampled = true
  let attributes: [String: AttributeValue] = [:]
}

package struct RuntimeTailSamplingSnapshot: Equatable, Sendable {
  package let retainedTraceCount: Int
  package let retainedSpanCount: Int
  package let retainedBreadcrumbCount: Int
  package let retainedByteEstimate: Int
}

package final class RuntimeTailSamplingCoordinator: @unchecked Sendable {
  private struct RetainedSpan {
    let value: SpanData
    let byteEstimate: Int
    let sequence: UInt64
  }

  private struct RetainedBreadcrumb {
    let value: ReadableLogRecord
    let byteEstimate: Int
    let sequence: UInt64

    var isError: Bool {
      value.severity == .error
    }
  }

  private struct TraceEntry {
    let createdAt: Date
    var headSampled: Bool
    var promoted: Bool
    var spans: [RetainedSpan]
    var breadcrumbs: [RetainedBreadcrumb]

    var byteEstimate: Int {
      spans.reduce(0) { $0 + $1.byteEstimate }
        + breadcrumbs.reduce(0) { $0 + $1.byteEstimate }
    }
  }

  private struct AcceptedTraceMarker {
    var hasAcceptedSpan: Bool
    var lastAccessSequence: UInt64
  }

  private struct Delivery {
    let traceID: TraceId
    let spans: [SpanData]
    let breadcrumbs: [ReadableLogRecord]
  }

  private struct Mutation {
    var delivery: Delivery?
    var orphanedErrors: [ReadableLogRecord] = []
    var retained = false
    var directLog: ReadableLogRecord?
  }

  private let lock = NSLock()
  private let policy: TelemetryTailSamplingPolicy
  private let headSampling: RuntimeHeadSamplingDecision
  private let clock: TelemetryRuntimeClock
  private let emitSpans: @Sendable ([SpanData]) -> RuntimeBatchQueueOfferResult
  private let emitLog: @Sendable (ReadableLogRecord) -> RuntimeBatchQueueOfferResult

  private var entries: [TraceId: TraceEntry] = [:]
  private var acceptedTraces: [TraceId: AcceptedTraceMarker] = [:]
  private var tombstones: [TraceId: Date] = [:]
  private var sequence: UInt64 = 0
  private var accepting = true
  private var expirationTask: Task<Void, Never>?
  private var expirationDeadline: Date?
  private var expirationGeneration = 0

  package init(
    policy: TelemetryTailSamplingPolicy,
    samplingRatio: Double,
    clock: TelemetryRuntimeClock,
    emitSpans: @escaping @Sendable ([SpanData]) -> RuntimeBatchQueueOfferResult,
    emitLog: @escaping @Sendable (ReadableLogRecord) -> RuntimeBatchQueueOfferResult
  ) {
    self.policy = policy
    headSampling = RuntimeHeadSamplingDecision(ratio: samplingRatio)
    self.clock = clock
    self.emitSpans = emitSpans
    self.emitLog = emitLog
  }

  package func record(span: SpanData) {
    let now = clock.now()
    let traceID = span.traceId
    let mutation = lock.withLock {
      var mutation = Mutation()
      mutation.orphanedErrors = pruneLocked(now: now)
      guard accepting else { return mutation }

      let headSampled = headSampling.isSampled(traceID: traceID)
      if headSampled {
        mutation.delivery = Delivery(traceID: traceID, spans: [span], breadcrumbs: [])
        scheduleExpirationLocked(now: now)
        return mutation
      }

      if acceptedTraces[traceID] != nil {
        touchAcceptedTraceLocked(traceID)
        mutation.delivery = deliveryAppendingSpanLocked(traceID: traceID, span: span)
        scheduleExpirationLocked(now: now)
        return mutation
      }
      guard tombstones[traceID] == nil else {
        scheduleExpirationLocked(now: now)
        return mutation
      }

      var entry = entryLocked(
        traceID: traceID,
        now: now,
        headSampled: false,
        orphanedErrors: &mutation.orphanedErrors
      )
      if entry.promoted {
        entries[traceID] = entry
        markTracePromotedLocked(traceID)
        mutation.delivery = deliveryAppendingSpanLocked(traceID: traceID, span: span)
      } else {
        sequence &+= 1
        entry.spans.append(
          RetainedSpan(
            value: span,
            byteEstimate: estimatedByteCount(span),
            sequence: sequence
          )
        )
        entries[traceID] = entry
        enforceBoundsLocked(
          protecting: traceID,
          orphanedErrors: &mutation.orphanedErrors
        )
        guard tombstones[traceID] == nil, var retained = entries[traceID] else {
          scheduleExpirationLocked(now: now)
          return mutation
        }
        let duration = span.endTime.timeIntervalSince(span.startTime)
        if span.status.isError || duration >= policy.slowTraceThreshold.runtimeSeconds {
          retained.promoted = true
          entries[traceID] = retained
          markTracePromotedLocked(traceID)
          mutation.delivery = drainDeliveryLocked(traceID: traceID)
        } else {
          mutation.retained = true
        }
      }
      scheduleExpirationLocked(now: now)
      return mutation
    }
    emitOrphanedErrors(mutation.orphanedErrors)
    if let delivery = mutation.delivery {
      _ = deliver(delivery)
    }
  }

  package func record(log: ReadableLogRecord) -> RuntimeBatchQueueOfferResult {
    guard
      let context = log.spanContext,
      context.isValid
    else {
      return emitLog(runtimeStrippingCorrelation(from: log))
    }

    let now = clock.now()
    let traceID = context.traceId
    let mutation = lock.withLock {
      var mutation = Mutation()
      mutation.orphanedErrors = pruneLocked(now: now)
      guard accepting else { return mutation }

      let headSampled = headSampling.isSampled(traceID: traceID)
      if headSampled {
        mutation.directLog = log
        scheduleExpirationLocked(now: now)
        return mutation
      }

      if let marker = acceptedTraces[traceID], marker.hasAcceptedSpan {
        touchAcceptedTraceLocked(traceID)
        mutation.directLog = log
        scheduleExpirationLocked(now: now)
        return mutation
      }
      if tombstones[traceID] != nil {
        if log.severity == .error {
          mutation.directLog = runtimeStrippingCorrelation(from: log)
        }
        return mutation
      }

      var entry = entryLocked(
        traceID: traceID,
        now: now,
        headSampled: false,
        orphanedErrors: &mutation.orphanedErrors
      )
      if acceptedTraces[traceID] != nil {
        entry.promoted = true
        touchAcceptedTraceLocked(traceID)
      }

      sequence &+= 1
      let retained = RetainedBreadcrumb(
        value: log,
        byteEstimate: estimatedByteCount(log),
        sequence: sequence
      )
      entry.breadcrumbs.append(retained)
      if log.severity == .error {
        entry.promoted = true
        markTracePromotedLocked(traceID)
      }
      entries[traceID] = entry
      enforceBoundsLocked(
        protecting: traceID,
        orphanedErrors: &mutation.orphanedErrors
      )
      guard tombstones[traceID] == nil, let current = entries[traceID] else {
        scheduleExpirationLocked(now: now)
        return mutation
      }
      mutation.retained = current.breadcrumbs.contains { $0.sequence == retained.sequence }
      if log.severity == .error, !mutation.retained {
        entries.removeValue(forKey: traceID)
        if acceptedTraces[traceID] == nil {
          tombstones[traceID] = now
          trimTombstonesLocked()
        }
        scheduleExpirationLocked(now: now)
        return mutation
      }
      if current.promoted, !current.spans.isEmpty {
        markTracePromotedLocked(traceID)
        mutation.delivery = drainDeliveryLocked(traceID: traceID)
      }
      scheduleExpirationLocked(now: now)
      return mutation
    }

    emitOrphanedErrors(mutation.orphanedErrors)
    if let directLog = mutation.directLog {
      return emitLog(directLog)
    }
    if let delivery = mutation.delivery {
      return deliver(delivery)
    }
    if !lock.withLock({ accepting }) {
      return .stopped
    }
    return mutation.retained ? .accepted : .dropped
  }

  package func promote(context: SpanContext) -> TelemetryTailPromotionResult {
    guard context.isValid else { return .noActiveTrace }
    let traceID = context.traceId
    if headSampling.isSampled(traceID: traceID) {
      return .alreadySampled
    }
    let now = clock.now()
    let mutation = lock.withLock {
      var mutation = Mutation()
      mutation.orphanedErrors = pruneLocked(now: now)
      guard accepting else { return mutation }
      guard tombstones[traceID] == nil else { return mutation }
      markTracePromotedLocked(traceID)
      mutation.retained = true
      if var entry = entries[traceID] {
        entry.promoted = true
        entries[traceID] = entry
        if !entry.spans.isEmpty {
          mutation.delivery = drainDeliveryLocked(traceID: traceID)
        }
      }
      scheduleExpirationLocked(now: now)
      return mutation
    }
    emitOrphanedErrors(mutation.orphanedErrors)
    guard mutation.retained else {
      return lock.withLock { accepting } ? .dropped : .disabled
    }
    guard let delivery = mutation.delivery else { return .promoted }
    return deliver(delivery) == .accepted ? .promoted : .dropped
  }

  package func forceFlush() {
    expire()
  }

  package func shutdown(exportUncorrelatedErrors: Bool) {
    let errors = lock.withLock {
      guard accepting else { return [ReadableLogRecord]() }
      accepting = false
      cancelExpirationLocked()
      let errors =
        exportUncorrelatedErrors
        ? entries.values.flatMap(\.breadcrumbs).filter(\.isError).map(\.value)
        : []
      entries.removeAll()
      acceptedTraces.removeAll()
      tombstones.removeAll()
      return errors
    }
    if exportUncorrelatedErrors {
      emitOrphanedErrors(errors)
    }
  }

  package var snapshot: RuntimeTailSamplingSnapshot {
    lock.withLock {
      RuntimeTailSamplingSnapshot(
        retainedTraceCount: entries.values.filter {
          !$0.spans.isEmpty || !$0.breadcrumbs.isEmpty
        }.count,
        retainedSpanCount: retainedSpanCountLocked,
        retainedBreadcrumbCount: retainedBreadcrumbCountLocked,
        retainedByteEstimate: retainedByteEstimateLocked
      )
    }
  }

  private func entryLocked(
    traceID: TraceId,
    now: Date,
    headSampled: Bool,
    orphanedErrors: inout [ReadableLogRecord]
  ) -> TraceEntry {
    if let entry = entries[traceID] {
      return entry
    }
    while entries.count >= policy.maximumTraceCount {
      guard let oldest = evictionVictimLocked(excluding: nil) else {
        break
      }
      orphanedErrors.append(contentsOf: discardEntryLocked(traceID: oldest, at: now))
    }
    let entry = TraceEntry(
      createdAt: now,
      headSampled: headSampled,
      promoted: headSampled,
      spans: [],
      breadcrumbs: []
    )
    entries[traceID] = entry
    return entry
  }

  private func enforceBoundsLocked(
    protecting traceID: TraceId,
    orphanedErrors: inout [ReadableLogRecord]
  ) {
    while retainedBreadcrumbCountLocked > policy.maximumRetainedBreadcrumbCount {
      guard let oldest = oldestBreadcrumbLocked() else { break }
      if oldest.breadcrumb.isError {
        orphanedErrors.append(oldest.breadcrumb.value)
      }
      entries[oldest.traceID]?.breadcrumbs.removeAll {
        $0.sequence == oldest.breadcrumb.sequence
      }
    }

    while retainedByteEstimateLocked > policy.maximumRetainedBytes,
      let oldest = oldestBreadcrumbLocked()
    {
      if oldest.breadcrumb.isError {
        orphanedErrors.append(oldest.breadcrumb.value)
      }
      entries[oldest.traceID]?.breadcrumbs.removeAll {
        $0.sequence == oldest.breadcrumb.sequence
      }
    }

    while retainedSpanCountLocked > policy.maximumRetainedSpanCount
      || retainedByteEstimateLocked > policy.maximumRetainedBytes
    {
      guard
        let oldest = evictionVictimLocked(
          excluding: traceID,
          requiringBufferedData: true
        )
      else {
        orphanedErrors.append(contentsOf: discardEntryLocked(traceID: traceID, at: clock.now()))
        return
      }
      orphanedErrors.append(
        contentsOf: discardEntryLocked(traceID: oldest, at: clock.now())
      )
    }

  }

  private func drainDeliveryLocked(traceID: TraceId) -> Delivery? {
    guard let entry = entries.removeValue(forKey: traceID) else { return nil }
    let spans = entry.spans.sorted {
      if $0.value.startTime == $1.value.startTime {
        return $0.sequence < $1.sequence
      }
      return $0.value.startTime < $1.value.startTime
    }.map(\.value)
    let breadcrumbs = entry.breadcrumbs.sorted { $0.sequence < $1.sequence }.map(\.value)
    return Delivery(traceID: traceID, spans: spans, breadcrumbs: breadcrumbs)
  }

  private func deliveryAppendingSpanLocked(
    traceID: TraceId,
    span: SpanData
  ) -> Delivery {
    guard let retained = drainDeliveryLocked(traceID: traceID) else {
      return Delivery(traceID: traceID, spans: [span], breadcrumbs: [])
    }
    return Delivery(
      traceID: traceID,
      spans: (retained.spans + [span]).sorted {
        if $0.startTime == $1.startTime {
          return $0.spanId.hexString < $1.spanId.hexString
        }
        return $0.startTime < $1.startTime
      },
      breadcrumbs: retained.breadcrumbs
    )
  }

  private func deliver(_ delivery: Delivery) -> RuntimeBatchQueueOfferResult {
    let spanResult =
      delivery.spans.isEmpty
      ? RuntimeBatchQueueOfferResult.accepted
      : emitSpans(delivery.spans)

    var logs = delivery.breadcrumbs
    let acceptedSpan = spanResult == .accepted
    let now = clock.now()
    lock.withLock {
      let headSampled = headSampling.isSampled(traceID: delivery.traceID)
      if acceptedSpan {
        if !headSampled {
          markTraceAcceptedLocked(delivery.traceID)
        }
        if let entry = entries.removeValue(forKey: delivery.traceID) {
          logs.append(contentsOf: entry.breadcrumbs.map(\.value))
        }
      } else {
        if let entry = entries.removeValue(forKey: delivery.traceID) {
          logs.append(contentsOf: entry.breadcrumbs.map(\.value))
        }
        if !headSampled {
          acceptedTraces.removeValue(forKey: delivery.traceID)
          tombstones[delivery.traceID] = now
          trimTombstonesLocked()
        }
      }
      scheduleExpirationLocked(now: now)
    }

    var result = spanResult
    if acceptedSpan {
      for log in logs {
        result = combining(result, emitLog(log))
      }
    } else {
      for log in logs where log.severity == .error {
        result = combining(result, emitLog(runtimeStrippingCorrelation(from: log)))
      }
    }
    return result
  }

  private func pruneLocked(now: Date) -> [ReadableLogRecord] {
    let maximumAge = policy.maximumAge.runtimeSeconds
    let expired = entries.filter {
      now.timeIntervalSince($0.value.createdAt) >= maximumAge
    }
    var errors: [ReadableLogRecord] = []
    for (traceID, entry) in expired {
      let accepted = acceptedTraces[traceID]?.hasAcceptedSpan == true
      if !accepted {
        errors.append(
          contentsOf: entry.breadcrumbs.filter(\.isError).map(\.value)
        )
      }
      entries.removeValue(forKey: traceID)
      if entry.promoted, !entry.headSampled {
        markTracePromotedLocked(traceID)
      } else if !entry.headSampled, acceptedTraces[traceID] == nil {
        tombstones[traceID] = now
      }
    }
    tombstones = tombstones.filter {
      now.timeIntervalSince($0.value) < maximumAge
    }
    trimTombstonesLocked()
    return errors
  }

  private func discardEntryLocked(traceID: TraceId, at now: Date) -> [ReadableLogRecord] {
    guard let entry = entries.removeValue(forKey: traceID) else { return [] }
    let accepted = acceptedTraces[traceID]?.hasAcceptedSpan == true
    if entry.promoted, !entry.headSampled {
      markTracePromotedLocked(traceID)
    } else if !entry.headSampled, acceptedTraces[traceID] == nil {
      tombstones[traceID] = now
      trimTombstonesLocked()
    }
    if !accepted {
      return entry.breadcrumbs.filter(\.isError).map(\.value)
    }
    return []
  }

  private func markTracePromotedLocked(_ traceID: TraceId) {
    sequence &+= 1
    let accepted = acceptedTraces[traceID]?.hasAcceptedSpan ?? false
    acceptedTraces[traceID] = AcceptedTraceMarker(
      hasAcceptedSpan: accepted,
      lastAccessSequence: sequence
    )
    tombstones.removeValue(forKey: traceID)
    trimAcceptedTracesLocked(protecting: traceID)
  }

  private func markTraceAcceptedLocked(_ traceID: TraceId) {
    sequence &+= 1
    acceptedTraces[traceID] = AcceptedTraceMarker(
      hasAcceptedSpan: true,
      lastAccessSequence: sequence
    )
    tombstones.removeValue(forKey: traceID)
    trimAcceptedTracesLocked(protecting: traceID)
  }

  private func touchAcceptedTraceLocked(_ traceID: TraceId) {
    guard var marker = acceptedTraces[traceID] else { return }
    sequence &+= 1
    marker.lastAccessSequence = sequence
    acceptedTraces[traceID] = marker
  }

  private func trimAcceptedTracesLocked(protecting traceID: TraceId) {
    while acceptedTraces.count > policy.maximumTraceCount {
      let candidates = acceptedTraces.filter { $0.key != traceID }
      guard
        let oldest = (candidates.isEmpty ? acceptedTraces : candidates)
          .min(by: { $0.value.lastAccessSequence < $1.value.lastAccessSequence })
      else {
        break
      }
      acceptedTraces.removeValue(forKey: oldest.key)
    }
  }

  private func evictionVictimLocked(
    excluding traceID: TraceId?,
    requiringBufferedData: Bool = false
  ) -> TraceId? {
    entries.filter { candidate in
      candidate.key != traceID
        && (!requiringBufferedData
          || !candidate.value.spans.isEmpty
          || !candidate.value.breadcrumbs.isEmpty)
    }.min { lhs, rhs in
      let lhsPriority = evictionPriority(lhs.value)
      let rhsPriority = evictionPriority(rhs.value)
      if lhsPriority == rhsPriority {
        return lhs.value.createdAt < rhs.value.createdAt
      }
      return lhsPriority < rhsPriority
    }?.key
  }

  private func evictionPriority(_ entry: TraceEntry) -> Int {
    if !entry.headSampled, !entry.promoted { return 0 }
    if entry.promoted, !entry.headSampled { return 1 }
    return 2
  }

  private func trimTombstonesLocked() {
    while tombstones.count > policy.maximumTraceCount {
      guard let oldest = tombstones.min(by: { $0.value < $1.value }) else { break }
      tombstones.removeValue(forKey: oldest.key)
    }
  }

  private var retainedSpanCountLocked: Int {
    entries.values.reduce(0) { $0 + $1.spans.count }
  }

  private var retainedBreadcrumbCountLocked: Int {
    entries.values.reduce(0) { $0 + $1.breadcrumbs.count }
  }

  private var retainedByteEstimateLocked: Int {
    entries.values.reduce(0) { $0 + $1.byteEstimate }
  }

  private func oldestBreadcrumbLocked() -> (
    traceID: TraceId, breadcrumb: RetainedBreadcrumb
  )? {
    entries.compactMap { traceID, entry in
      entry.breadcrumbs.min(by: { $0.sequence < $1.sequence }).map {
        (traceID, $0)
      }
    }.min { $0.1.sequence < $1.1.sequence }
  }

  private func scheduleExpirationLocked(now: Date) {
    let deadline =
      accepting
      ? entries.values.map {
        $0.createdAt.addingTimeInterval(policy.maximumAge.runtimeSeconds)
      }.min()
      : nil
    guard deadline != expirationDeadline else { return }

    expirationTask?.cancel()
    expirationTask = nil
    expirationGeneration += 1
    expirationDeadline = deadline
    guard let deadline else { return }

    let generation = expirationGeneration
    let delay = max(0.001, deadline.timeIntervalSince(now))
    expirationTask = Task { [weak self, clock] in
      do {
        try await clock.sleep(.runtimeSeconds(delay))
      } catch {
        return
      }
      self?.expirationElapsed(generation: generation)
    }
  }

  private func cancelExpirationLocked() {
    guard expirationTask != nil || expirationDeadline != nil else { return }
    expirationTask?.cancel()
    expirationTask = nil
    expirationDeadline = nil
    expirationGeneration += 1
  }

  private func expirationElapsed(generation: Int) {
    let errors = lock.withLock {
      guard accepting, generation == expirationGeneration else { return [ReadableLogRecord]() }
      expirationTask = nil
      expirationDeadline = nil
      let now = clock.now()
      let errors = pruneLocked(now: now)
      scheduleExpirationLocked(now: now)
      return errors
    }
    emitOrphanedErrors(errors)
  }

  private func expire() {
    let errors = lock.withLock {
      let now = clock.now()
      let errors = pruneLocked(now: now)
      scheduleExpirationLocked(now: now)
      return errors
    }
    emitOrphanedErrors(errors)
  }

  private func emitOrphanedErrors(_ logs: [ReadableLogRecord]) {
    for log in logs {
      _ = emitLog(runtimeStrippingCorrelation(from: log))
    }
  }
}

private func combining(
  _ lhs: RuntimeBatchQueueOfferResult,
  _ rhs: RuntimeBatchQueueOfferResult
) -> RuntimeBatchQueueOfferResult {
  if lhs == .stopped || rhs == .stopped { return .stopped }
  if lhs == .dropped || rhs == .dropped { return .dropped }
  return .accepted
}

package func runtimeStrippingCorrelation(from record: ReadableLogRecord) -> ReadableLogRecord {
  ReadableLogRecord(
    resource: record.resource,
    instrumentationScopeInfo: record.instrumentationScopeInfo,
    timestamp: record.timestamp,
    observedTimestamp: record.observedTimestamp,
    spanContext: nil,
    severity: record.severity,
    body: record.body,
    attributes: record.attributes,
    eventName: record.eventName
  )
}

private func estimatedByteCount(_ span: SpanData) -> Int {
  160 + span.name.utf8.count
    + estimatedByteCount(span.attributes)
    + span.events.reduce(0) {
      $0 + 40 + $1.name.utf8.count + estimatedByteCount($1.attributes)
    }
}

private func estimatedByteCount(_ record: ReadableLogRecord) -> Int {
  128 + (record.eventName?.utf8.count ?? 0)
    + (record.body?.description.utf8.count ?? 0)
    + estimatedByteCount(record.attributes)
}

private func estimatedByteCount(_ attributes: [String: AttributeValue]) -> Int {
  attributes.reduce(0) {
    $0 + 16 + $1.key.utf8.count + $1.value.description.utf8.count
  }
}
