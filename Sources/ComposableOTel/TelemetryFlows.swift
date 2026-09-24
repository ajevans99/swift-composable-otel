import Dependencies
import OpenTelemetryApi

/// Runs throwing work as an explicit root flow with no reducer parent.
///
/// Use this for entry points outside a reducer, such as app launch, push handling, background
/// refresh, or widget timelines. It starts a new trace with a parentless `tca.effect` span named by
/// `flow`, marks it `tca.flow.root = true`, and emits the effect lifecycle logs and metrics. Dependency
/// calls, instrumented dependency clients, and navigation recorded inside `operation` become its
/// children and carry `feature`.
public func withTracedRootFlow<T: Sendable>(
  feature: FeatureID,
  flow: EffectID,
  operation: @Sendable () async throws -> T
) async throws -> T {
  if ReducerTraceContext.instrumentationSuppressed {
    return try await operation()
  }
  @Dependency(\.composableOTel) var telemetry
  return try await telemetry.withEffectTrace(
    effect: flow,
    longLived: false,
    parentContext: nil,
    feature: telemetry.policy.schema.bounded(feature),
    root: true,
    operation: operation
  )
}

/// Runs nonthrowing work as an explicit root flow with no reducer parent.
public func withTracedRootFlow<T: Sendable>(
  feature: FeatureID,
  flow: EffectID,
  operation: @Sendable () async -> T
) async -> T {
  if ReducerTraceContext.instrumentationSuppressed {
    return await operation()
  }
  @Dependency(\.composableOTel) var telemetry
  do {
    return try await telemetry.withEffectTrace(
      effect: flow,
      longLived: false,
      parentContext: nil,
      feature: telemetry.policy.schema.bounded(feature),
      root: true,
      operation: { await operation() }
    )
  } catch {
    preconditionFailure("A nonthrowing root flow cannot throw")
  }
}

extension OperationID {
  /// Reads or queries a resource.
  public static var fetch: TelemetryIdentifier<OperationIdentifierKind> { "fetch" }
  /// Creates or updates a resource.
  public static var save: TelemetryIdentifier<OperationIdentifierKind> { "save" }
  /// Removes a resource.
  public static var delete: TelemetryIdentifier<OperationIdentifierKind> { "delete" }
  /// Observes a long-lived sequence of values.
  public static var stream: TelemetryIdentifier<OperationIdentifierKind> { "stream" }
  /// Reconciles local and remote state.
  public static var sync: TelemetryIdentifier<OperationIdentifierKind> { "sync" }
  /// Authenticates or authorizes the user or device.
  public static var authorize: TelemetryIdentifier<OperationIdentifierKind> { "authorize" }
}

/// Central, consistent instrumentation for every endpoint of one dependency client.
///
/// Wrap each closure of a `@DependencyClient` once, typically in its `liveValue`, so every call gets a
/// `tca.dependency` span, lifecycle logs, and metrics named by the same bounded ``DependencyID`` and
/// an ``OperationID``. Arguments, return values, stream elements, and error descriptions are passed
/// through untouched and never inspected or exported.
///
/// ```swift
/// extension PlansClient: DependencyKey {
///   static let liveValue: Self = {
///     let telemetry = TelemetryDependencyInstrumentation("plans-client")
///     let base = Self.unimplementedLive
///     return Self(
///       fetchPlans: telemetry.instrument(.fetch, base.fetchPlans),
///       savePlan: telemetry.instrument(.save, base.savePlan),
///       planUpdates: telemetry.instrumentStream(.stream, base.planUpdates)
///     )
///   }()
/// }
/// ```
public struct TelemetryDependencyInstrumentation: Sendable {
  /// The bounded dependency name applied to every instrumented operation.
  public let dependency: DependencyID

  public init(_ dependency: DependencyID) {
    self.dependency = dependency
  }

  /// Traces one invocation of an arbitrary operation.
  public func call<T: Sendable>(
    _ operation: OperationID,
    _ body: @Sendable () async throws -> T
  ) async throws -> T {
    try await tracedCall(dependency: dependency, operation: operation, operation: body)
  }

  /// Traces one invocation of an arbitrary nonthrowing operation.
  public func call<T: Sendable>(
    _ operation: OperationID,
    _ body: @Sendable () async -> T
  ) async -> T {
    await tracedCall(dependency: dependency, operation: operation, operation: body)
  }

  /// Wraps a throwing async endpoint so every call is traced as `operation`.
  public func instrument<each Argument: Sendable, Result: Sendable>(
    _ operation: OperationID,
    _ endpoint: @escaping @Sendable (repeat each Argument) async throws -> Result
  ) -> @Sendable (repeat each Argument) async throws -> Result {
    let dependency = dependency
    return { (argument: repeat each Argument) in
      let invocation = UncheckedSendableInvocation { try await endpoint(repeat each argument) }
      return try await tracedCall(dependency: dependency, operation: operation) {
        try await invocation.body()
      }
    }
  }

  /// Wraps a nonthrowing async endpoint so every call is traced as `operation`.
  public func instrument<each Argument: Sendable, Result: Sendable>(
    _ operation: OperationID,
    _ endpoint: @escaping @Sendable (repeat each Argument) async -> Result
  ) -> @Sendable (repeat each Argument) async -> Result {
    let dependency = dependency
    return { (argument: repeat each Argument) in
      let invocation = UncheckedSendableInvocation { await endpoint(repeat each argument) }
      return await tracedCall(dependency: dependency, operation: operation) {
        await invocation.body()
      }
    }
  }

  /// Wraps a throwing stream endpoint so each subscription is traced from first iteration until the
  /// upstream finishes, throws, or the consumer cancels.
  public func instrumentStream<each Argument: Sendable, Element: Sendable>(
    _ operation: OperationID,
    _ endpoint:
      @escaping @Sendable (repeat each Argument) -> AsyncThrowingStream<Element, any Error>
  ) -> @Sendable (repeat each Argument) -> AsyncThrowingStream<Element, any Error> {
    let dependency = dependency
    return { (argument: repeat each Argument) in
      let upstream = endpoint(repeat each argument)
      return AsyncThrowingStream { continuation in
        let task = Task {
          do {
            try await tracedCall(dependency: dependency, operation: operation) {
              for try await element in upstream {
                continuation.yield(element)
              }
              try Task.checkCancellation()
            }
            continuation.finish()
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }

  /// Wraps a nonthrowing stream endpoint so each subscription is traced from first iteration until
  /// the upstream finishes or the consumer cancels.
  public func instrumentStream<each Argument: Sendable, Element: Sendable>(
    _ operation: OperationID,
    _ endpoint: @escaping @Sendable (repeat each Argument) -> AsyncStream<Element>
  ) -> @Sendable (repeat each Argument) -> AsyncStream<Element> {
    let dependency = dependency
    return { (argument: repeat each Argument) in
      let upstream = endpoint(repeat each argument)
      return AsyncStream { continuation in
        let task = Task {
          try? await tracedCall(dependency: dependency, operation: operation) {
            for await element in upstream {
              continuation.yield(element)
            }
            try Task.checkCancellation()
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  }
}

// Swift 6.1 does not infer Sendable for captured parameter packs whose elements are Sendable, and
// pack-generic types need watchOS 10, so the call is boxed as a closure over Sendable arguments.
private struct UncheckedSendableInvocation<Body>: @unchecked Sendable {
  let body: Body

  init(_ body: Body) {
    self.body = body
  }
}
