#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly lock_file="$repository_root/API/SemanticConventions.lock"
readonly reviewed_upstream="v1.43.0"
cd "$repository_root"

actual_hash="$(
  shasum -a 256 \
    Sources/ComposableOTel/Attributes.swift \
    Sources/ComposableOTel/SemanticConventions.swift \
    | shasum -a 256 \
    | awk '{print $1}'
)"
expected_hash="$(awk '$1 == "source-sha256" { print $2 }' "$lock_file")"
lock_upstream="$(awk '$1 == "upstream" { print $2 }' "$lock_file")"

if [[ "$lock_upstream" != "$reviewed_upstream" ]]; then
  echo "Semantic convention review must name upstream $reviewed_upstream" >&2
  exit 1
fi
if [[ "$actual_hash" != "$expected_hash" ]]; then
  echo "Semantic convention source changed without updating API/SemanticConventions.lock" >&2
  echo "Expected: $expected_hash" >&2
  echo "Actual:   $actual_hash" >&2
  exit 1
fi
if ! grep -q "$reviewed_upstream" \
  Sources/ComposableOTel/Documentation.docc/Articles/SemanticConventions.md
then
  echo "DocC semantic convention review is missing upstream $reviewed_upstream" >&2
  exit 1
fi

echo "Semantic conventions match the reviewed $reviewed_upstream lock"
