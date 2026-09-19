#!/bin/bash
# The retirement suite, compiled with swiftc because it needs nothing but
# Foundation: the step reads and moves files and hands dictations to a sink.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
XCODE_SDK="$(xcrun --show-sdk-path)"
BIN="$(mktemp -d /tmp/vf-s6-retirement.XXXXXX)/retirement"
trap 'rm -rf "$(dirname "$BIN")"' EXIT
swiftc -sdk "$XCODE_SDK" -suppress-warnings \
    swift/Captured/Retirement/DataSourcesRetirement.swift \
    tests/data_sources_retirement/main.swift \
    -o "$BIN"
"$BIN"
