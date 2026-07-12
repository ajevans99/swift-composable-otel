# Consumer Pilot Evidence Contract

The production-like consumer pilot is owned outside this package repository. The package does not
add consumer-specific APIs, deploy infrastructure, or treat a successful request as pilot approval.
Issue #6 remains open until the evidence below is linked and reviewed.

## Required evidence package

The pilot report must identify:

1. The consumer repository commit, package commit or pre-release tag, app version, platform versions,
   device classes, and test dates.
2. The consumer-owned facade and kill-switch boundaries, confirming package types do not leak into
   feature-domain APIs.
3. The bounded schema review: enabled signals, sampling rules, finite identifiers, error
   classifications, cardinality estimates, and sentinel-secret tests.
4. The TLS ingestion-gateway architecture, credential lifetime and scope, per-attempt rotation test,
   rate limits, and redacted failure evidence. No credential or private endpoint belongs in the
   report.
5. End-to-end trace evidence for reducer to effect to dependency parentage across suspension and
   child tasks, plus the documented detached-task boundary.
6. End-to-end metrics and logs with trace sampling both enabled and disabled, proving signal
   independence and log defaults.
7. Deterministic scenarios for offline queueing, relaunch recovery, persistence corruption,
   overflow/drop, retry exhaustion, non-retryable failure, background deadline, force flush,
   shutdown, gateway rejection, and failure isolation.
8. Credential rotation and exporter-diagnostic evidence, including attempts, successes,
   retryable/non-retryable failures, drops, persistence growth, corruption recovery, and kill-switch
   behavior.
9. Repeated measurements for launch and steady-state CPU, action/effect latency, memory high-water,
   battery impact, bytes sent, request count, drop rate, persistence size, and background execution.
   Include the workload, sample count, device state, baseline without telemetry, and acceptance
   thresholds.
10. A privacy and security review stating what was inspected, sentinel values used, whether any
    action, state, payload, URL, raw error, credential, or unapproved identifier escaped, and who
    accepted residual risk.

## Review outcome

The package release record must link the immutable pilot report and record reviewer, review date,
pass/fail status, unresolved findings, and explicitly accepted residual risk. Missing, partial, or
unreviewed evidence is a no-go. This checklist intentionally contains no pre-filled Momentum result.
