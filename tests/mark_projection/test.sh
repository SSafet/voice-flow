#!/bin/bash
# S3 — MarkProjector against two displays of different scale.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d /tmp/vf-s3-mark-projection.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc -sdk "$SDK" -suppress-warnings -o "$OUT/mark_projection" \
    -framework Cocoa -framework CoreGraphics \
    swift/Generated/PlatformContracts.swift \
    swift/DisplayContext.swift \
    swift/Captured/Marks/MarkProjector.swift \
    tests/mark_projection/main.swift
"$OUT/mark_projection"
