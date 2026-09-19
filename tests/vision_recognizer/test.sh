#!/bin/bash
# VisionTextRecognizer — the one real-image test: Apple's Vision reads a
# committed fixture picture (07 §3.5). No database, so plain swiftc builds it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f swift/Captured/VisionTextRecognizer.swift ]; then
    echo "vision recognizer: swift/Captured/VisionTextRecognizer.swift does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-vision-recognizer.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swiftc -o "$WORK/vision_recognizer" -sdk "$SDK" -suppress-warnings \
    swift/Captured/TextRecognizer.swift \
    swift/Captured/VisionTextRecognizer.swift \
    tests/vision_recognizer/main.swift \
    -framework Vision -framework CoreGraphics -framework ImageIO
"$WORK/vision_recognizer"
