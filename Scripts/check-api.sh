#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

find .build -type d -name symbolgraph -prune -exec rm -rf {} +
log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

set +e
xcrun swift package dump-symbol-graph \
  --minimum-access-level public \
  --skip-synthesized-members \
  --skip-inherited-docs 2>&1 | tee "$log_file"
dump_status="${PIPESTATUS[0]}"
set -e

graph_directory="$(
  sed -n 's/^Files written to //p' "$log_file" \
    | tail -1
)"
if [[ -z "$graph_directory" || ! -d "$graph_directory" ]]; then
  echo "SwiftPM did not report a symbol graph output directory" >&2
  exit 1
fi

for module in ComposableOTel ComposableOTelExporters ComposableOTelTesting; do
  if [[ ! -f "$graph_directory/$module.symbols.json" ]]; then
    echo "SwiftPM did not emit the required $module symbol graph" >&2
    exit 1
  fi
done

if [[ "$dump_status" != "0" ]]; then
  if grep -q "Failed to emit symbol graph for 'swift_composable_otelPackageTests'" "$log_file"; then
    echo "Ignoring the SwiftPM package-test symbol graph bug; all library graphs were emitted" >&2
  else
    echo "SwiftPM symbol graph extraction failed" >&2
    exit "$dump_status"
  fi
fi

xcrun swift Scripts/check-api.swift \
  --symbol-graphs "$graph_directory" \
  --baseline API/PublicAPI.json

bash Scripts/check-unsafe-api.sh
