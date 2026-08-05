#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly fixture="$repository_root/Tests/CompileFixtures/PrivacyAwareLogs"
readonly log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

set +e
xcrun swift build \
  --package-path "$fixture" \
  --scratch-path "$repository_root/.build/privacy-aware-logs-fixture" \
  >"$log_file" 2>&1
status="$?"
set -e

if [[ "$status" == "0" ]]; then
  echo "Privacy-aware log compile fixture unexpectedly succeeded" >&2
  exit 1
fi

for value in \
  stringLiteral \
  appendLiteral \
  bareString \
  customValue \
  runtimeError \
  runtimeURL \
  consumerIdentifier
do
  if ! grep -q "$value" "$log_file"; then
    cat "$log_file" >&2
    echo "Compile failure did not prove $value is unavailable for public interpolation" >&2
    exit 1
  fi
done

echo "Unbounded runtime values are unavailable for public log interpolation"
