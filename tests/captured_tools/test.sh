#!/bin/bash
# CapturedTools — the ten tools, one registration, one handler, the common
# rules (limits, the notice, secret scrubbing, pictures as image blocks with
# `_meta`), and the pictures reduced to 400 KB each and 4.8 MB per result
# (07 §3.6, §3.9). Needs GRDB and the app's image helpers.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "captured tools: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -f swift/Captured/Tools/CapturedTools.swift ]; then
    echo "captured tools: swift/Captured/Tools/CapturedTools.swift does not exist yet" >&2
    exit 1
fi
if [ ! -f contract-schemas/platform-contracts.schema.json ]; then
    echo "captured tools: contract-schemas/platform-contracts.schema.json is missing — run scripts/sync-thread-protocol.sh" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-captured-tools.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
swiftc -o "$WORK/captured_tools" -sdk "$SDK" -suppress-warnings \
    -I "$BIN/Modules" -L "$BIN" -lGRDB \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/ScreenCapture.swift \
    swift/AssistantWake.swift \
    swift/Assistants.swift \
    swift/AgentCapabilities.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/ContextRules.swift \
    swift/Captured/Store/*.swift \
    swift/Captured/Query/*.swift \
    swift/Captured/Tools/*.swift \
    tests/captured_tools/main.swift \
    -framework Cocoa -framework CoreGraphics -framework ScreenCaptureKit
"$WORK/captured_tools"
