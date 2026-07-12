#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly log_file="$(mktemp)"
readonly derived_data_path="${DERIVED_DATA_PATH:-$(mktemp -d)}"

cleanup() {
  rm -f "$log_file"
  if [[ -z "${DERIVED_DATA_PATH:-}" ]]; then
    rm -rf "$derived_data_path"
  fi
}
trap cleanup EXIT

cd "$repository_root"

if ! {
  for scheme in ComposableOTel ComposableOTelExporters ComposableOTelTesting; do
    xcodebuild \
      -quiet \
      -skipMacroValidation \
      -scheme "$scheme" \
      -destination "generic/platform=macOS" \
      -derivedDataPath "$derived_data_path" \
      docbuild
  done
} >"$log_file" 2>&1
then
  cat "$log_file" >&2
  exit 1
fi

project_diagnostics="$(
  grep -F "$repository_root/" "$log_file" \
    | grep -E '(warning|error):' \
    || true
)"
if [[ -n "$project_diagnostics" ]]; then
  printf '%s\n' "$project_diagnostics" >&2
  exit 1
fi

echo "DocC catalogs built without project diagnostics"
