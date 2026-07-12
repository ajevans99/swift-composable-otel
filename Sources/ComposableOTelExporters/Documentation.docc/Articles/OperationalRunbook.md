# Operational Runbook

Operate `TelemetryRuntime` as a bounded, best-effort mobile delivery system rather than a guaranteed
message queue.

## Diagnose delivery

Read the synchronous `diagnostics` snapshot and the structured diagnostic handler outside the
OpenTelemetry pipeline:

| Observation | Meaning | Response |
| --- | --- | --- |
| `queueDepth` rises | Producers are outpacing delivery or export is paused. | Check export condition and gateway health; reduce signal volume before raising a reviewed bound. |
| `droppedItems` rises | A queue, attempt budget, persistence write, or non-retryable request rejected work. | Correlate with failure counters and queue configuration; do not assume retry will recover it. |
| `retryableFailures` rises | A timeout, transient transport error, or retryable HTTP status occurred. | Check network and gateway availability; confirm backoff and attempt budgets. |
| `nonRetryableFailures` rises | Authentication, configuration, host classification, or a terminal HTTP response failed. | Validate endpoint, fresh credentials, gateway policy, and transport classification. |
| `persistedItems` grows | Sanitized batches are waiting on disk. | Check export condition, credentials, gateway response, file protection, and storage limits. |
| `recoveredCorruptFiles` rises | An unreadable or unsupported spool record was removed. | Inspect storage pressure and app lifecycle; never attempt to transmit the removed bytes. |
| `timedOutFlushes` rises | A lifecycle deadline expired with pending work. | Record the host-provided budget and pending counts; delivery after suspension is not possible. |

`lastSuccess` proves only that one request was accepted by the configured transport. It does not
prove backend ingestion, indexing, retention, or alerting.

## Lifecycle procedure

1. Retain one runtime at the composition root.
2. Call `applicationDidBecomeActive()` when the host resumes eligible work.
3. Pass only the actual remaining background budget to `applicationDidEnterBackground`.
4. Inspect the returned per-signal status and pending/drop counts.
5. Call `shutdown` once during orderly termination where execution time exists. Concurrent calls
   coalesce; later activation cannot restart a shut-down runtime.

The host owns any UIKit, SwiftUI scene, background-task, or termination integration.

## Authentication incident

Disable export with `setExportCondition(.unavailable)` or the host kill switch, revoke the affected
credential, and correct the host authenticator or gateway. Authorization is reacquired on every
attempt and is not persisted, but the host must confirm that no credential was emitted by its own
custom transport or diagnostics.

## Persistence incident

Spool files contain sanitized OTLP bodies and allowlisted content headers. They remain subject to the
configured protection class, age, and byte bounds. On suspected exposure, disable export, preserve
only non-sensitive diagnostic counts, follow the host application's incident process, and remove
files through normal application storage controls. Do not upload raw spool contents to a public
issue.
