#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${SWIFT_EXEC:-}" ]]; then
  swift_command=("$SWIFT_EXEC")
elif command -v xcrun >/dev/null 2>&1; then
  swift_command=(xcrun swift)
else
  swift_command=(swift)
fi

cd "$repository_root"

if git ls-files --error-unmatch Package.resolved >/dev/null 2>&1; then
  echo "Package.resolved must remain untracked for this library package" >&2
  exit 1
fi

if [[ "${SWIFT_PACKAGE_DISABLE_SANDBOX:-0}" == "1" ]]; then
  "${swift_command[@]}" package --disable-sandbox dump-package >/dev/null
else
  "${swift_command[@]}" package dump-package >/dev/null
fi
"${swift_command[@]}" Scripts/validate-documentation.swift
