#!/bin/bash
# CapturedQuery.frames, .around and .summary — the three range reads of 07 §3.6.
# Needs GRDB.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "captured ranges: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -f swift/Captured/Query/CapturedQuery.swift ]; then
    echo "captured ranges: swift/Captured/Query/CapturedQuery.swift does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-captured-ranges.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
swiftc -o "$WORK/captured_ranges" -sdk "$SDK" -suppress-warnings \
    -I "$BIN/Modules" -L "$BIN" -lGRDB \
    swift/VoiceFlowPaths.swift \
    swift/AssistantWake.swift \
    swift/Assistants.swift \
    swift/AgentCapabilities.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/ContextRules.swift \
    swift/Captured/Store/*.swift \
    swift/Captured/Query/*.swift \
    tests/captured_ranges/main.swift \
    -framework Cocoa -framework CoreGraphics
"$WORK/captured_ranges"
