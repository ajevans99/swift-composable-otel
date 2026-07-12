#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly output_path="${BENCHMARK_OUTPUT_PATH:-$repository_root/.build/benchmark-results.json}"
cd "$repository_root"

mkdir -p "$(dirname "$output_path")"
xcrun swift run \
  --configuration release \
  ComposableOTelBenchmarks \
  --output "$output_path"

echo "Benchmark report written to $output_path"
