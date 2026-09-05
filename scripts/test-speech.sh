#!/bin/bash
# Focused API speech gate; no live requests or microphone capture.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="$(mktemp -d /tmp/voice-flow-speech-tests.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$BUILD_DIR/config"
.venv/bin/python -m unittest discover -s tests -p test_backend_protocol.py -v
.venv/bin/python -m unittest discover -s tests -p test_speech_performance.py -v
swiftc swift/SpeechTransport.swift tests/speech_transport/main.swift -o "$BUILD_DIR/transport"
"$BUILD_DIR/transport"
swiftc swift/VoiceFlowPaths.swift swift/AgentRuntimeTypes.swift swift/AgentSourceConfiguration.swift \
    swift/SystemAgents.swift swift/SpeechSanitizer.swift tests/speech_sanitizer/main.swift -o "$BUILD_DIR/sanitizer"
"$BUILD_DIR/sanitizer"
APP_SOURCES=()
for source in swift/*.swift; do
    [ "$(basename "$source")" = main.swift ] || APP_SOURCES+=("$source")
done
for suite in speech_speed audio_recorder; do
    swiftc -D VOICE_FLOW_QA -O -whole-module-optimization -suppress-warnings \
        "${APP_SOURCES[@]}" "tests/$suite/main.swift" -o "$BUILD_DIR/$suite" \
        -framework Cocoa -framework AVFoundation -framework CoreGraphics \
        -framework ApplicationServices -framework Accelerate -framework Security \
        -framework ScreenCaptureKit -lsqlite3
    "$BUILD_DIR/$suite"
done
printf 'Speech regression gate passed\n'
