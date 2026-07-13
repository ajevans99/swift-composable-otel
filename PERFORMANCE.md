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
| Registered delta counter | 250,000 ns/add |
| Conservative gateway trace batch | 25 items and at most 64 KiB encoded |
| Sampled versus unsampled | At most 5.0× |
| Queue high-water growth | At most 64 MiB while accounting for 4,096 offered spans |

The queue scenario requires every offered item to be represented by current queue depth, successful
delivery, or a drop; requires both accepted and dropped work under pressure; and enforces the
configured 2,048-item delivery ceiling. Results are uploaded from CI as a deterministic JSON report.

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

These ceilings are regression gates, not latency, battery, memory, network, or delivery SLAs for an
application. A 1.0 decision requires reviewed hosted-CI results plus real consumer-pilot measurements
using [PILOT.md](PILOT.md). Budget changes require a benchmark report, rationale, and release review;
raising a number only to make CI pass is not acceptable.
