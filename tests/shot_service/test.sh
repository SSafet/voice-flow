#!/bin/bash
# S3 — ShotService: the one way a screenshot exists, marked and clean.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d /tmp/vf-s3-shot-service.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc -sdk "$SDK" -suppress-warnings -o "$OUT/shot_service" \
    -framework Cocoa -framework CoreGraphics -framework ScreenCaptureKit \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/Generated/PlatformContracts.swift \
    swift/ScreenCapture.swift \
    swift/Captured/Marks/MarkProjector.swift \
    swift/Captured/Marks/MarkRenderer.swift \
    swift/Captured/ShotService.swift \
    tests/shot_service/main.swift
"$OUT/shot_service"
