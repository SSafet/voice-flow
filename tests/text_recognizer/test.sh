#!/bin/bash
# TextRecognizer — the skip rules and the backlog that works through the
# pictures no one has read yet (07 §3.5). Vision is behind the protocol, so
# this suite runs with a fake recogniser; the real one has its own suite.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "text recognizer: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -f swift/Captured/TextRecognitionBacklog.swift ]; then
    echo "text recognizer: swift/Captured/TextRecognitionBacklog.swift does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-text-recognizer.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
swiftc -o "$WORK/text_recognizer" -sdk "$SDK" -suppress-warnings \
    -I "$BIN/Modules" -L "$BIN" -lGRDB \
    swift/VoiceFlowPaths.swift \
    swift/Captured/ContextRules.swift \
    swift/Captured/Store/*.swift \
    swift/Captured/TextRecognizer.swift \
    swift/Captured/TextRecognitionPolicy.swift \
    swift/Captured/TextRecognitionBacklog.swift \
    tests/text_recognizer/main.swift \
    -framework Cocoa -framework CoreGraphics
"$WORK/text_recognizer"
