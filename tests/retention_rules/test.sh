#!/bin/bash
# The retention table, the budget setting and the thinning keep-list. Pure
# Swift over S1's value enums and the generated contract, so no database and
# no GRDB are needed.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -d swift/Captured/Store ]; then
    echo "retention rules: swift/Captured/Store does not exist yet — S1 has not landed on this branch" >&2
    exit 1
fi
if [ ! -d swift/Captured/Retention ]; then
    echo "retention rules: swift/Captured/Retention does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-retention-rules.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swiftc -o "$WORK/retention_rules" -sdk "$SDK" -suppress-warnings \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/Store/CapturedValues.swift \
    swift/Captured/Retention/RetentionRules.swift \
    tests/retention_rules/main.swift
"$WORK/retention_rules"
