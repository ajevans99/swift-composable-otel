#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

for scheme in ComposableOTel ComposableOTelExporters ComposableOTelTesting; do
  xcodebuild \
    -quiet \
    -skipMacroValidation \
    -scheme "$scheme" \
    -destination "generic/platform=watchOS" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build
done
