#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d /tmp/vf-device-auth.XXXXXX)"
FIXTURE_PID=""
cleanup() { if [[ -n "$FIXTURE_PID" ]]; then kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; fi; rm -rf "$WORK"; }
trap cleanup EXIT
node "$ROOT/tests/cloud_device_auth/server.mjs" "$WORK/fixture.json" >"$WORK/server.log" 2>&1 &
FIXTURE_PID=$!
for _ in {1..100}; do [[ -f "$WORK/fixture.json" ]] && break; kill -0 "$FIXTURE_PID" 2>/dev/null || { cat "$WORK/server.log"; exit 1; }; sleep 0.05; done
[[ -f "$WORK/fixture.json" ]]
swiftc -parse-as-library -swift-version 5 "$ROOT/swift/CloudSyncModels.swift" "$ROOT/swift/CloudSyncStore.swift" \
  "$ROOT/swift/CloudSyncHTTP.swift" "$ROOT/tests/cloud_device_auth/main.swift" -lsqlite3 -o "$WORK/test"
"$WORK/test" "$WORK/fixture.json"
