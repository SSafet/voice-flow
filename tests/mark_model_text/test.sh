#!/bin/bash
# S3 — the text a model reads when marks travel with a picture.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d /tmp/vf-s3-mark-model-text.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc -sdk "$SDK" -suppress-warnings -o "$OUT/mark_model_text" \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/Marks/MarkModelText.swift \
    tests/mark_model_text/main.swift
"$OUT/mark_model_text"
