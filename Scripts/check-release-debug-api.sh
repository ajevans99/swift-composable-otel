#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly fixture="$repository_root/Tests/CompileFixtures/ReleaseDebugRenderer"
readonly log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

set +e
xcrun swift build \
  --configuration release \
  --package-path "$fixture" \
  --scratch-path "$repository_root/.build/release-debug-renderer-fixture" \
  >"$log_file" 2>&1
status="$?"
set -e

if [[ "$status" == "0" ]]; then
  echo "DEBUG-only renderer unexpectedly compiled in release mode" >&2
  exit 1
fi

for symbol in TelemetryDebugConsoleRenderer debugConsole; do
  if ! grep -q "$symbol" "$log_file"; then
    cat "$log_file" >&2
    echo "Release compile failure did not prove $symbol is unavailable" >&2
    exit 1
  fi
done

echo "Private console rendering is unavailable in release builds"
