# Production Readiness Gates

Package CI checks the reusable evidence that can be produced without a consumer application:

- reducer, effect, dependency, signal, privacy, runtime, persistence, lifecycle, and concurrency
  behavior;
- minimum and latest dependency endpoint jobs;
- current iOS simulator tests, generic iOS product builds, and macOS tests;
- target and runtime coverage floors;
- Thread Sanitizer on macOS;
- public API and semantic-convention locks;
- release performance, memory, batching, and queue budgets; and
- all three DocC catalogs.

watchOS is not declared. The inherited graph fails the named watchOS support gate in the TCA
dependency under Xcode 27, and no support claim is made from an ad hoc partial build.

A consumer pilot, privacy review, battery and network measurements, ingestion-gateway operation,
credential service, default-branch protection, required-check settings, and final residual-risk
acceptance are external evidence. Their absence blocks 1.0 rather than weakening package gates.
