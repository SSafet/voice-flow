#!/bin/bash
# ContextProbe and its rules. Pure Swift over the generated contract types —
# no database, so plain swiftc builds it and it runs before the Swift Package
# Manager build exists.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-captured-context.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
# Never the owner's real data folder.
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swiftc -o "$WORK/captured_context" -sdk "$SDK" -suppress-warnings \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/ContextRules.swift \
    swift/Captured/ContextProbe.swift \
    tests/captured_context/main.swift \
    -framework Cocoa -framework CoreGraphics
"$WORK/captured_context"
