#!/bin/bash
# The watcher's private-picture rule: WatcherPolicy's decision and S1's
# ContextRules that feeds it. No database, so plain swiftc builds it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f swift/Captured/ContextRules.swift ]; then
    echo "private capture: swift/Captured/ContextRules.swift does not exist yet — S1 has not landed on this branch" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-private-capture.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swiftc -o "$WORK/private_capture" -sdk "$SDK" -suppress-warnings \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/ContextRules.swift \
    swift/WatcherPolicy.swift \
    tests/private_capture/main.swift \
    -framework Cocoa -framework CoreGraphics
"$WORK/private_capture"
