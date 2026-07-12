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

swift_package() {
  if [[ "${SWIFT_PACKAGE_DISABLE_SANDBOX:-0}" == "1" ]]; then
    "${swift_command[@]}" package --disable-sandbox "$@"
  else
    "${swift_command[@]}" package "$@"
  fi
}

resolve_exact() {
  local package="$1"
  local version="$2"

  swift_package resolve "$package" --version "$version"
  if ! grep -A6 "\"identity\" : \"$package\"" Package.resolved \
    | grep -q "\"version\" : \"$version\""
  then
    echo "Expected $package $version in Package.resolved" >&2
    exit 1
  fi
}

case "${1:-}" in
minimum)
  resolve_exact opentelemetry-swift-core 2.3.0
  resolve_exact swift-composable-architecture 1.17.0
  resolve_exact swift-dependencies 1.4.0
  resolve_exact xctest-dynamic-overlay 1.9.0
  ;;
latest)
  swift_package resolve
  ;;
*)
  echo "Usage: $0 <minimum|latest>" >&2
  exit 64
  ;;
esac
