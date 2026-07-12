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
rm -f Package.resolved

manifest_backup=""
cleanup() {
  if [[ -n "$manifest_backup" ]]; then
    cp -p "$manifest_backup" Package.swift
    rm -f "$manifest_backup"
  fi
}
trap cleanup EXIT

swift_package() {
  if [[ "${SWIFT_PACKAGE_DISABLE_SANDBOX:-0}" == "1" ]]; then
    "${swift_command[@]}" package --disable-sandbox "$@"
  else
    "${swift_command[@]}" package "$@"
  fi
}

verify_resolved() {
  local package="$1"
  local version="$2"

  if ! grep -A6 "\"identity\" : \"$package\"" Package.resolved \
    | grep -q "\"version\" : \"$version\""
  then
    echo "Expected $package $version in Package.resolved" >&2
    exit 1
  fi
}

case "${1:-}" in
minimum)
  manifest_backup="$(mktemp)"
  cp -p Package.swift "$manifest_backup"

  requirement_count="$(grep -c 'from: "' Package.swift)"
  if [[ "$requirement_count" != "4" ]]; then
    echo "Expected four direct minimum-version requirements in Package.swift" >&2
    exit 1
  fi

  perl -pi -e 's/\bfrom: /exact: /g' Package.swift
  swift_package resolve

  verify_resolved opentelemetry-swift-core 2.3.0
  verify_resolved swift-composable-architecture 1.17.0
  verify_resolved swift-dependencies 1.4.0
  verify_resolved xctest-dynamic-overlay 1.9.0
  ;;
latest)
  swift_package resolve
  ;;
*)
  echo "Usage: $0 <minimum|latest>" >&2
  exit 64
  ;;
esac
