# Security Policy

## Supported versions

The latest tagged release receives security fixes. Unreleased behavior on `main` is not a supported
release. Before 1.0, a security fix may require a documented source-compatible or breaking minor
release when preserving the existing API would leave consumers exposed.

## Reporting a vulnerability

Use the repository's
[private vulnerability reporting](https://github.com/ajevans99/swift-composable-otel/security/advisories/new)
flow. Do not include credentials, production telemetry, customer data, or an unpatched exploit in a
public issue.

Include the affected tag or commit, platform and toolchain, reproduction, impact, and any known
mitigation. The maintainer will coordinate disclosure and release timing on a best-effort basis; this
project does not promise a response or remediation SLA.

## Security boundary

The package validates TLS endpoints but does not own certificate policy, an ingestion gateway,
identity issuance, backend authorization, retention, or access control. Hosts must:

- acquire narrow, short-lived credentials outside package configuration;
- refresh authorization in `TelemetryRequestAuthenticator` for each attempt;
- keep vendor and gateway secrets out of source, application bundles, telemetry, and persistence;
- authenticate and rate-limit the ingestion gateway; and
- review the explicitly unsafe custom SDK boundary before production use.

See [PRIVACY.md](PRIVACY.md) and the operational runbook for data-handling and incident guidance.
