#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

coverage_path="$(xcrun swift test --show-codecov-path)"
if [[ ! -f "$coverage_path" ]]; then
  echo "Coverage JSON not found; run swift test --enable-code-coverage first" >&2
  exit 1
fi

xcrun swift Scripts/check-coverage.swift "$coverage_path"
