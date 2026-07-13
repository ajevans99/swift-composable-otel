# Consumer Pilot Evidence Contract

The production-like pilot is owned by a consumer application outside this package repository. The
package does not add consumer-specific APIs, deploy infrastructure, or treat one accepted request as
pilot approval. A 1.0 release remains blocked until every required artifact below is linked and
reviewed.

## Evidence roles

| Evidence report | Required scope |
| --- | --- |
| Package integration evidence | Exact package pin, consumer-owned facade, runtime composition, lifecycle wiring, bounded schema/configuration locations, and debug/staging selection. |
| Gateway and export evidence | TLS gateway, short-lived authentication, per-signal endpoints, rejection/queue diagnostics, credential rotation/revocation, and remote backend receipt. |
| Representative TCA flow evidence | One reducer to effect to dependency flow with success, cancellation, and failure evidence. |
| Physical-device release evidence | Release-build runs; offline/background behavior; authentication rotation/failure; kill switch and opt-out; sentinel/privacy review; and performance, network, disk, and drop budgets. |

## Gateway contract evidence

A gateway capped at a compressed and decoded OTLP body of 64 KiB, 50 signal items, and 5 seconds
uses the package's reviewed conservative profile: a 64 KiB encoded ceiling, no more than 25
trace/log items per batch, and a 5-second request timeout. The runtime drops an oversized encoded
body before persistence or transport and reports `oversizedRequests` plus `droppedItems`.

Custom metric arrays are partitioned by actual point count before encoding. Points inside one
oversized `MetricData` cannot be split, so that record is dropped with a bounded diagnostic. The
package also rejects registered counter catalogs whose declared maximum-series sum exceeds
`maximumContractMetricPointsPerRequest` (50 by default).
The gateway must also prove:

- numeric `Retry-After` carries any required next-minute jitter and is within the configured maximum;
- HTTP 401 invalidates host credentials without retrying the failed batch;
- HTTP 413 is a visible terminal drop rather than a silent retry; and
- production resources and principals are isolated from non-production environments.

## Evidence index

Every submission must identify immutable or access-controlled locations for:

1. The consumer repository commit, exact package tag and commit, app version, schema source, facade
   source, runtime/lifecycle composition, signal configuration, and release-build configuration.
2. The gateway source/configuration revision and deployment identifier, redacted traces, metrics, and
   logs endpoint configuration, reviewed retention configuration, and backend receipt/query/artifact
   location for each signal. Never copy a credential or private endpoint value into this repository.
3. The physical device model and OS version, release-build commit and archive/workflow artifact, test
   date, scenario/run identifier, and corresponding backend receipt location.
4. The evidence artifact for every failure-mode and budget row below, including its workload,
   baseline, sample count, threshold, observed result, reviewer, and review date.

## Acceptance checklists

### Package integration

- Pin an exact package tag and commit; a branch or open version range is insufficient evidence.
- Link the consumer-owned facade and prove feature-domain APIs do not expose package types.
- Link runtime creation, dependency injection, active/background/shutdown/discard lifecycle wiring,
  debug/staging selection, kill-switch entry point, and bounded schema/configuration source.
- Record enabled signals, trace sampling, log defaults, finite identifiers, error classifications,
  cardinality estimates, persistence posture, queue limits, and accepted platform constraints.

### Gateway, authentication, and receipt

- Link the TLS gateway, collector, authentication, and deployment revisions plus redacted per-signal
  endpoint configuration.
- Record credential issuer, lifetime, scope, storage posture, per-attempt refresh, rotation, expiry,
  revocation, and application opt-out behavior without publishing a credential.
- Exercise accepted requests, authentication rejection, non-retryable gateway rejection, retryable
  failure, retry exhaustion, queue/drop diagnostics, and recovery after rotation.
- Link physical-device backend receipt evidence for traces, metrics, and logs, including exact
  workspace/query/artifact locations and bounded identifiers that correlate them to the pilot run.
- Prove synchronous metrics export and contract-compliant retention.
- Prove the 64 KiB/50-item/5-second contract and 401/413/429 behavior above.
- Link separately owned production resources and principals rather than reusing non-production
  identities or workspaces.

### Representative TCA flow

- Link one reducer to effect to dependency flow and its schema identifiers.
- For success, cancellation, and failure, record reducer, effect, and dependency span identifiers,
  trace/parent relationships, terminal effect outcome, active-count balance, error classification,
  and corresponding metric/log evidence.
- Include suspension and inherited child-task propagation. Record the documented detached-task
  boundary if the representative flow uses detached work.

### Physical-device release evidence

- Run a release build on a physical device and link device/build/run metadata.
- Exercise offline queueing, relaunch recovery, background deadline, force flush, orderly shutdown,
  terminal discard, overflow, corruption recovery, and failure isolation.
- Exercise authentication success, rotation, expiry/rejection, recovery, and revocation while
  recording attempts, successes, retryable/non-retryable failures, pending work, and drops.
- Exercise the kill switch and opt-out path, proving the host swaps to `TelemetryClient.noop`,
  discard does not flush, persisted/in-memory telemetry is removed, and later lifecycle updates do
  not restart the runtime.
- Record sentinel values used to prove that action, state, payload, URL, raw error, credential, and
  unapproved identifiers do not reach queues, disk, network, or the backend.
- Report release-build CPU/action/effect latency, memory high-water, bytes and requests sent,
  persistence bytes, drop rate, and background behavior against reviewed performance, network, disk,
  and drop budgets. A specific dashboard or OS metrics framework is not required; the method must be
  reproducible and reviewed.

## Review outcome

The package release record must map every checklist item to an immutable evidence location and record
reviewer, review date, pass/fail status, unresolved findings, and explicitly accepted residual risk.
Missing, partial, inaccessible, or unreviewed evidence is a no-go. This contract intentionally
contains no pre-filled consumer result.
