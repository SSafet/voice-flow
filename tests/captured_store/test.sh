#!/bin/bash
# The captured index's own database. It needs GRDB, so it is built the way the
# app is built (K8's Package.swift) and linked against the package's products.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "captured store: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -d swift/Captured/Store ]; then
    echo "captured store: swift/Captured/Store does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-captured-store.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
# The flags that link a suite against the package's GRDB, for either products layout.
. tests/grdb_flags.sh
swiftc -o "$WORK/captured_store" -sdk "$SDK" -suppress-warnings \
    "${GRDB_LINK[@]}" \
    swift/VoiceFlowPaths.swift \
    swift/Captured/Store/*.swift \
    tests/captured_store/main.swift
"$WORK/captured_store"
