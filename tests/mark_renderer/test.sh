#!/bin/bash
# S3 — MarkRenderer, the one drawing code for the eight kinds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d /tmp/vf-s3-mark-renderer.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc -sdk "$SDK" -suppress-warnings -o "$OUT/mark_renderer" \
    -framework Cocoa -framework CoreGraphics \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Annotation.swift \
    swift/Captured/Marks/MarkRenderer.swift \
    swift/Captured/Marks/MarkRenderer+Canvas.swift \
    tests/mark_renderer/main.swift
"$OUT/mark_renderer"
