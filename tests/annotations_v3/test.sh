#!/bin/bash
# S3 — annotations.json version 3, and the conversion to the contract's Mark.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d /tmp/vf-s3-annotations-v3.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc -sdk "$SDK" -suppress-warnings -o "$OUT/annotations_v3" \
    -framework Cocoa -framework CoreGraphics \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Annotation.swift \
    swift/Captured/Marks/MarkConversion.swift \
    tests/annotations_v3/main.swift
"$OUT/annotations_v3"
