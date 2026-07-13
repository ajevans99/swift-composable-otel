#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly fixture="$repository_root/Tests/CompileFixtures/UnsafeAPI"
readonly log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

set +e
xcrun swift build \
  --package-path "$fixture" \
  --scratch-path "$repository_root/.build/unsafe-api-fixture" \
  >"$log_file" 2>&1
status="$?"
set -e

if [[ "$status" == "0" ]]; then
  echo "Unsafe API compile fixture unexpectedly succeeded" >&2
  exit 1
fi

for symbol in \
  unsafeCustomSDK \
  MetricInstruments \
  sanitizedSpanAttributes \
  PrivacyPreservingSpanExporter \
  ComposableOTelMetricConfiguration
do
  if ! grep -q "$symbol" "$log_file"; then
    cat "$log_file" >&2
    echo "Compile failure did not prove $symbol is unavailable" >&2
    exit 1
  fi
done

echo "Unsafe implementation APIs are unavailable to normal package consumers"
