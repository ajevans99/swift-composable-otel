# Production Readiness Gates

Package CI checks the reusable evidence that can be produced without a consumer application:

- reducer, effect, dependency, signal, privacy, runtime, persistence, lifecycle, terminal
  consent-revocation discard, and concurrency behavior;
- minimum and latest dependency endpoint jobs;
- current iOS simulator tests, generic iOS/watchOS product builds, and macOS tests;
- target and runtime coverage floors;
- Thread Sanitizer on macOS;
- public API and semantic-convention locks;
- release performance, memory, batching, queue, and tail-retention budgets; and
- all three DocC catalogs.

watchOS 9 is supported. Every public product, including selective TCA reducer instrumentation, must
compile for a generic watchOS device in the latest-dependency lane.

A consumer pilot, privacy review, battery and network measurements, ingestion-gateway operation,
credential service, default-branch protection, required-check settings, and final residual-risk
acceptance are external evidence. Their absence blocks 1.0 rather than weakening package gates.
