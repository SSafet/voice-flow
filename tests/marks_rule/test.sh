#!/bin/bash
# S3 — the contract's Mark rule in Swift, held to the contract's fixtures.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="$(xcrun --show-sdk-path)"
OUT="$(mktemp -d /tmp/vf-s3-marks-rule.XXXXXX)"
trap 'rm -rf "$OUT"' EXIT

swiftc -sdk "$SDK" -suppress-warnings -o "$OUT/marks_rule" \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/Marks/MarkRule.swift \
    tests/marks_rule/main.swift
"$OUT/marks_rule"
