#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d /tmp/vf-t3-app-host.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library -swift-version 5 "$ROOT/swift/T3ApplicationLocation.swift" \
 "$ROOT/swift/NativeTools/T3NativeControlActivity.swift" "$ROOT/swift/T3ApplicationShutdown.swift" "$ROOT/swift/CloudNativeHomeSelection.swift" \
 "$ROOT/tests/t3_application_host/main.swift" -o "$WORK/proof"
"$WORK/proof"
