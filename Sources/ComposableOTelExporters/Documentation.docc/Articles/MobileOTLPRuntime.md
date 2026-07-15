# Mobile OTLP Runtime

Own a bounded production OTLP/HTTP pipeline without exposing exporter SDK types to features.

## Compose the runtime

Create one ``TelemetryRuntime`` at the application composition root and retain it for the process
lifetime:

```swift
let runtime = try TelemetryRuntime(
  configuration: .init(
    serviceName: "example-app",
    endpoints: OTLPEndpoints(
      baseURL: URL(string: "https://telemetry.example.com/otlp")!
    ),
    policy: policy
  ),
  authenticator: .init { request in
    var request = request
    let credential = try await credentialProvider.shortLivedCredential()
    request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    return request
  }
)
```

Inject `runtime.client` into TCA dependencies. The runtime keeps tracer, meter, logger, processors,
readers, exporters, queues, persistence, and shutdown state private.

Resource mode defaults to `.native(environment: .production)`, preserving
service/environment/Darwin/OpenTelemetry
SDK/distribution attributes. Use `.strict(resourceValue)` only for a registered resource definition;
strict mode emits exactly its required keys plus integer contract version and rejects an environment
mismatch before providers are created.

Endpoints require HTTPS by default and must include a host. Embedded URL credentials, query strings,
and fragments are rejected before providers are built. The API intentionally has no static header
dictionary. The authenticator is called immediately before every attempt and its output is never
persisted.

To send from a local simulator to a local collector, opt in explicitly:

```swift
let configuration = TelemetryRuntime.Configuration(
  serviceName: "example-app",
  endpoints: OTLPEndpoints(baseURL: URL(string: "http://localhost:4318")!),
  endpointSecurity: .allowInsecureHTTPForLoopbackInDevelopmentOrTest,
  resourceMode: .native(environment: .development)
)
```

``TelemetryEndpointSecurityPolicy/allowInsecureHTTPForLoopbackInDevelopmentOrTest`` accepts HTTP
only when the effective native or strict resource environment is `development` or `test` and every
signal endpoint host is exactly `localhost`, a dotted-decimal address in `127.0.0.0/8`, or `::1`.
Staging, production, LAN and other non-loopback hosts, mixed local/remote endpoint sets, and
alternate numeric host spellings remain rejected. HTTPS remains accepted in every environment.

## Use a gateway and expiring credentials

Send telemetry to an application-owned ingestion gateway rather than embedding a backend or vendor
key in the application:

1. The application asks its backend for a narrow, short-lived ingestion credential.
2. The backend may validate an App Attest or DeviceCheck assertion before issuing that credential.
3. The runtime authenticator adds the credential to one request attempt.
4. The gateway authenticates, rate-limits, and forwards OTLP to the selected observability backend.

The package does not deploy or require a particular gateway, backend, vendor, token format, App
Attest protocol, or credential service.

## Understand the bounded pipeline

Span and log processors sanitize records before inserting them into finite queues. Metric views
filter instruments and dimensions before collection. Every signal is sanitized again before the
official OTLP/HTTP encoder creates a request. Only that sanitized encoded request can reach optional
persistence or the host transport.

Queue size, batch size, schedule delay, exporter timeout, pending request count, encoded request
bytes, request timeout, overflow policy, retry attempts, backoff, jitter, metric interval, and flush
deadlines are finite and configurable. `.dropOldest` and `.dropNewest` make overflow deterministic.
Registered operational events share the bounded log queue and delivery signal, while their
`operationalEventsEnabled` acceptance control remains independent from package-owned logs.
Sanitized signal arrays are officially encoded and recursively split in order before persistence and
transport until every request fits `maximumEncodedRequestBytes`. A single record whose encoded body
still exceeds the ceiling, or an unmeasurable body stream, is dropped with bounded diagnostics.

HTTP 408, 425, 429, 502, 503, and 504 plus selected transient `URLError` values are retryable. Other
responses, including 401 and 413, are non-retryable. `TelemetryRetryClassifyingError` lets host
transports and authenticators classify their own errors. For 429 only, a numeric `Retry-After`
represented by ``TelemetryHTTPResponse/retryAfter`` replaces exponential backoff and is clamped to
the configured maximum. Exponential backoff is otherwise capped, jitter is bounded, task
cancellation stops the attempt, and authorization is reacquired before every retry. A custom
transport may invalidate host credentials when it observes 401 before returning that response.

For a gateway capped at 64 KiB compressed/decoded bodies, 50 items, and a 5-second request, use the
reviewed conservative profile: 25-item trace/log batches, a 64 KiB encoded ceiling, and a 5-second
request timeout. `maximumContractMetricPointsPerRequest` rejects registered counter catalogs whose
declared maximum-series sum exceeds the configured cap and partitions encoded metric records by
actual point count. It cannot split the points inside one `MetricData`; a single metric record above
the cap is a bounded non-retryable drop with a `metricPointLimitExceeded` diagnostic.

The package's OTLP exporters do not enable compression, so this ceiling applies to the decoded
protobuf body. A custom transport that compresses the request must enforce its compressed-body limit
after compression.

``TelemetryExportCondition`` is a scheduling hint. An unavailable hint pauses new attempts, but an
available hint never proves that DNS, TLS, authentication, the gateway, or the backend will work.

## Persist only sanitized requests

Optional persistence writes one encoded request per atomic file. The spool is excluded from backup,
uses a configured Apple file-protection class, and has maximum byte and age limits. Authorization,
cookies, and arbitrary request headers are excluded. Relaunch recovery keeps valid records and
removes corrupt, unsupported, expired, or oversized records.

The default `.completeUntilFirstUserAuthentication` protection supports post-first-unlock background
access on iOS. macOS relies on the host volume's protection posture in addition to the file
attributes.

## Forward lifecycle budgets

The package does not import UIKit or register host background tasks. Forward lifecycle events from
SwiftUI, UIKit, AppKit, or BackgroundTasks:

```swift
await runtime.applicationDidBecomeActive()
let result = await runtime.applicationDidEnterBackground(
  remainingTime: hostRemainingBudget
)
let shutdown = await runtime.shutdown(timeout: .seconds(5))
```

The host owns `UIApplication.beginBackgroundTask`, `BGTaskScheduler` registration and completion, or
macOS termination coordination. Pass only the remaining budget. ``TelemetryRuntimeOperationResult``
reports per-signal success, failure, timeout, pending, and drop state. Shutdown is idempotent.

## Revoke consent and discard unsent data

Graceful shutdown attempts a final bounded flush and retains timed-out persistence for relaunch.
Consent revocation requires different behavior. Swap the host facade or dependency to
`TelemetryClient.noop` first so no feature can start new instrumentation, then call:

```swift
telemetryFacade.replaceClient(with: .noop)
let result = await runtime.disableAndDiscardPending()
```

``TelemetryRuntime/disableAndDiscardPending()`` does not flush. It permanently rejects new signal
data, cancels in-flight delivery and retry work, deletes its in-memory queues and every spool file,
and shuts down its providers. Later active-lifecycle or export-condition calls cannot resume it.
Concurrent calls are idempotent. Deletion failures are returned without escaping into application
behavior and can be retried by calling the operation again.

## Treat delivery as best-effort

iOS and watchOS can suspend or terminate the process before a schedule fires, a retry completes, an
atomic write finishes, or a flush returns. watchOS background execution is especially constrained;
the host must forward its actual remaining lifecycle budget and must not assume periodic or
post-suspension delivery. No package code can export while suspended or after force-quit,
termination, crash, or device shutdown. Persistence creates another bounded opportunity after
relaunch; it is not a delivery guarantee.

Use ``TelemetryRuntimeDiagnostics`` or the optional structured diagnostic handler for queue depth,
drops, persisted bytes/items, attempts, successes, retryable/non-retryable failures, last success,
corruption recovery, and flush/discard outcomes. Diagnostics bypass OpenTelemetry and contain only
bounded categories and counts, so exporter failures cannot recursively generate more exporter
telemetry.

Use <doc:OperationalRunbook> for failure response and <doc:ProductionReadiness> for the package,
platform, pilot, and release gates that must pass before stable production use.
