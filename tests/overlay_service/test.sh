#!/bin/bash
# S3 — OverlayService: validation, ownership, one path, display identity.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d /tmp/vf-s3-overlay-service.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc -sdk "$SDK" -suppress-warnings -o "$OUT/overlay_service" \
    -framework Cocoa -framework CoreGraphics \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/Marks/MarkRule.swift \
    swift/Captured/OverlayService.swift \
    tests/overlay_service/main.swift
"$OUT/overlay_service"
