#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/voice-flow-panel-focus.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$BUILD_DIR/config"
SOURCES=()
for source in "$PROJECT_DIR"/swift/*.swift; do
    if [ "$(basename "$source")" != "main.swift" ]; then
        SOURCES+=("$source")
    fi
done
swiftc "${SOURCES[@]}" "$PROJECT_DIR/tests/panel_focus/main.swift" \
    -framework Cocoa -framework AVFoundation -framework CoreGraphics \
    -framework ApplicationServices -framework Accelerate -framework Security \
    -framework ScreenCaptureKit -lsqlite3 -suppress-warnings -o "$BUILD_DIR/panel-focus"
"$BUILD_DIR/panel-focus"
