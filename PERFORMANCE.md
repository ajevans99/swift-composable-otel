# Performance and Memory Budgets

The release benchmark is `ComposableOTelBenchmarks`, run by `Scripts/run-benchmarks.sh` in a release
configuration. Each timing reports the median of five samples after warm-up and fails above the
checked budget in `Benchmarks/ComposableOTelBenchmarks/Budgets.json`.

## Reviewed ceilings

| Scenario | Budget |
| --- | ---: |
| Reducer, signals disabled | 50,000 ns/action |
| Instrumented reducer | 250,000 ns/action |
| Reducer with state-change token | 300,000 ns/action |
| Dependency wrapper | 500,000 ns/call |
| Effect wrapper through a TCA store | 1,000,000 ns/effect |
| Navigation logging | 100,000 ns/record |
| Metric recording | 100,000 ns/record |
| Sampled span | 250,000 ns/span |
| Unsampled span | 100,000 ns/span |
| Runtime batching | 300,000 ns/item |
| Registered catalog span | 2,000,000 ns/span |
| Registered bodyless log | 250,000 ns/record |
| Registered operational-event creation | 250,000 ns/record |
| Registered delta counter | 250,000 ns/add |
| Runtime configuration construction | 100,000 ns/configuration |
| Runtime provider startup | 50,000,000 ns/runtime |
| Tail-retained sanitized span | 500,000 ns/span |
| Conservative gateway trace batch | 25 items and at most 64 KiB encoded |
| Sampled versus unsampled | At most 5.0× |
| Queue high-water growth | At most 64 MiB while accounting for 4,096 offered spans |
| Default tail retention | 32 traces, 256 spans, 128 breadcrumbs, 512 KiB, 30 seconds |
| Tail-buffer high-water growth | At most 32 MiB while accounting for 4,096 offered spans |

The queue scenario requires every offered item to be represented by current queue depth, successful
delivery, or a drop; requires both accepted and dropped work under pressure; and enforces the
configured 2,048-item delivery ceiling. Results are uploaded from CI as a deterministic JSON report.
Tail fixtures independently enforce trace, span, breadcrumb, byte-estimate, age, and resident-memory
limits and prove that evicted unpromoted entries never reach persistence or transport.

The benchmark catalog's metric has an explicit four-series ceiling. Its event field has two allowed
values and its boolean field has two, so the checked metric cross-product cannot exceed that ceiling.
No general histogram is exposed for rc.6. Consequently the package emits no histogram exemplars from
this surface. The default exporter boundary removes all exemplars; the opt-in bounded policy retains
only valid SDK trace/span context and removes every exemplar attribute, so session context cannot
reappear in either metric labels or exemplar attributes.

## Baseline and interpretation

The reviewed 2026-07-12 baseline used an Apple Silicon host, a release build, Xcode 27 beta 3, and
Swift 6.4. Observed medians were 3.4 microseconds for a disabled reducer, 22.2 microseconds for an
instrumented reducer, 24.0 microseconds with a state token, 25.9 microseconds for a dependency call,
138.5 microseconds for an effect, 4.8 microseconds for logging, 2.4 microseconds for metrics, 14.1
microseconds for a sampled span, 3.4 microseconds for an unsampled span, and 8.5 microseconds for
batching. The observed sampled/unsampled ratio was 4.11 and queue high-water growth was 8.7 MiB.
The conservative 25-item maximum-identifier navigation batch encoded to about 1.4 KiB. A separate
worst-case SDK-boundary test fills all 16 span attributes and four maximum-identifier error events
per span and requires the 25-span request to remain at or below 64 KiB.

The 2026-07-12 typed-catalog baseline measured 1.18 milliseconds per active custom span, 8.3
microseconds per bodyless log, and 2.8 microseconds per delta counter add under concurrent local build
load. Their checked ceilings include hosted-runner headroom and remain regression gates rather than
application latency guarantees.

The 2026-08-05 rc.5 probe measured registered operational-event creation at 16.9 microseconds, runtime
configuration construction at 4.4 microseconds, runtime provider startup at 0.53 milliseconds, and a
sanitized head-missed span retained by the bounded tail coordinator at 36.2 microseconds. After 4,096
head-missed spans, the tail fixture retained 32 traces and 32 spans using a 10.3 KiB encoded-size
estimate and a 9.9 MiB resident high-water delta. Its queue and gateway fixtures retained the existing
64 MiB memory ceiling and 64 KiB encoded-request ceiling.

These ceilings are regression gates, not latency, battery, memory, network, or delivery SLAs for an
application. A 1.0 decision requires reviewed hosted-CI results plus real consumer-pilot measurements
using [PILOT.md](PILOT.md). Budget changes require a benchmark report, rationale, and release review;
raising a number only to make CI pass is not acceptable.
