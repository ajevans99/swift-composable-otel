#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly graph_directory="$repository_root/.build/out/symbolgraph"
cd "$repository_root"

rm -rf "$graph_directory"
xcrun swift package dump-symbol-graph \
  --minimum-access-level public \
  --skip-synthesized-members \
  --skip-inherited-docs

xcrun swift Scripts/check-api.swift \
  --symbol-graphs "$graph_directory" \
  --baseline API/PublicAPI.json
