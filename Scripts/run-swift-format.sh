#!/usr/bin/env bash

set -euo pipefail

readonly formatter_repository="https://github.com/swiftlang/swift-format.git"
readonly formatter_commit="d54c5be7afba3e5f52ae29e2371e444a3c2a49c1"
readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly tool_root="${SWIFT_FORMAT_TOOL_DIR:-$repository_root/.build/tools/swift-format-$formatter_commit}"
readonly source_path="$tool_root/source"
readonly build_path="$tool_root/build"

if [[ ! -d "$source_path/.git" ]]; then
  rm -rf "$source_path"
  mkdir -p "$tool_root"
  git clone --filter=blob:none --no-checkout "$formatter_repository" "$source_path"
fi

git -C "$source_path" fetch --depth 1 origin "$formatter_commit"
git -C "$source_path" checkout --detach --force "$formatter_commit"
if [[ "$(git -C "$source_path" rev-parse HEAD)" != "$formatter_commit" ]]; then
  echo "Resolved swift-format commit does not match the repository pin" >&2
  exit 1
fi

xcrun swift build \
  --package-path "$source_path" \
  --scratch-path "$build_path" \
  --configuration release \
  --product swift-format
bin_path="$(
  xcrun swift build \
    --package-path "$source_path" \
    --scratch-path "$build_path" \
    --configuration release \
    --show-bin-path
)"

exec "$bin_path/swift-format" "$@"
