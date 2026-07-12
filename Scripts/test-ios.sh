#!/usr/bin/env bash

set -euo pipefail

readonly repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

destination_id="$(
  xcrun simctl list devices available --json \
    | /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    for device in devices[runtime]:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            print(device["udid"])
            raise SystemExit(0)
raise SystemExit("No available iPhone simulator")
'
)"

xcodebuild \
  -quiet \
  -skipMacroValidation \
  -scheme swift-composable-otel-Package \
  -destination "platform=iOS Simulator,id=$destination_id" \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test
