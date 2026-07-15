# swift-composable-otel 0.3.1

0.3.1 is a source-compatible pre-1.0 patch release that corrects local simulator OTLP endpoint
validation. It does not weaken the runtime's production security defaults.

## Local loopback OTLP development

`TelemetryRuntime.Configuration` now has an explicit endpoint security policy:

```swift
let configuration = TelemetryRuntime.Configuration(
  serviceName: "example-app",
  endpoints: OTLPEndpoints(baseURL: URL(string: "http://localhost:4318")!),
  endpointSecurity: .allowInsecureHTTPForLoopbackInDevelopmentOrTest,
  resourceMode: .native(environment: .development)
)
```

The existing initializer remains source-compatible and defaults to
`TelemetryEndpointSecurityPolicy.requireHTTPS`. The opt-in permits HTTP only when:

- the effective native or strict resource environment is `development` or `test`; and
- every trace, metric, and log endpoint host is exactly `localhost`, canonical dotted-decimal
  `127.0.0.0/8`, or `::1`.

Staging, production, LAN and other non-loopback hosts, mixed local/remote endpoint sets, mapped or
alternate numeric host spellings, embedded credentials, queries, fragments, and non-HTTP schemes
remain rejected before providers are created. HTTPS remains accepted in every environment.

## Compatibility and migration

0.3.1 adds API without removing or changing the 0.3.0 public surface. Existing HTTPS configurations
require no migration. Local development callers must select the explicit policy and a development or
test resource environment.

The broader 0.2.2-to-0.3.x migration remains documented in [MIGRATION.md](MIGRATION.md).

## Accepted residual risks

This patch does not change the accepted pre-1.0 risks or satisfy any 1.0 go/no-go item.

| Risk | Scope and mitigation | Owner | Reviewer | Reconsideration |
| --- | --- | --- | --- | --- |
| Missing external production-like evidence | No external consumer has supplied the physical-device, gateway, privacy, delivery, and resource-usage evidence defined in [PILOT.md](PILOT.md). Package-owned CI and bounded defaults reduce risk; adopters must complete that evidence contract for their own production use. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Unprotected default branch | Repository administration does not enforce default-branch protection or required checks. The maintainer must verify the complete hosted release CI on the exact release commit before tagging; protection remains mandatory for 1.0. | `ajevans99` | `ajevans99` | 2026-10-13 |
| Exact empty `severity_text` unsupported | The upstream OpenTelemetry Swift model and encoder cannot represent an explicitly empty severity-text field through supported APIs. 0.3.1 guarantees the documented EventName, severity, body, typed-field, and contract-version behavior and does not add a raw encoding bypass. | `ajevans99` | `ajevans99` | 2026-10-13 |
| watchOS unsupported | The manifest supports iOS and macOS only because the inherited graph has not passed the named watchOS gate. The package makes no watchOS claim until all products compile, maintained CI exercises the relevant surface, and lifecycle limits are documented. | `ajevans99` | `ajevans99` | 2026-10-13 |

The complete 1.0 go/no-go decision remains defined in [RELEASING.md](RELEASING.md).
