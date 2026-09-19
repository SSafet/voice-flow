#!/bin/bash
# RetentionSweeper over a real captured index and a real folder. Needs GRDB,
# so it is built the way the app is built (K8's Package.swift) and linked
# against the package's products.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "retention sweep: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -d swift/Captured/Store ]; then
    echo "retention sweep: swift/Captured/Store does not exist yet — S1 has not landed on this branch" >&2
    exit 1
fi
if [ ! -d swift/Captured/Retention ]; then
    echo "retention sweep: swift/Captured/Retention does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-retention-sweep.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
GRDB_OBJECT="$(/usr/bin/find "$BIN" -maxdepth 1 -name 'GRDB.o' -print -quit)"
GRDB_MODULEMAP="$(/usr/bin/find "$REPO_ROOT/.build" -path '*GRDBSQLite*' -name 'module.modulemap' -print -quit)"
if [ -z "$GRDB_OBJECT" ] || [ -z "$GRDB_MODULEMAP" ]; then
    echo "retention sweep: GRDB's object file or GRDBSQLite's module map is not where this runner looks." >&2
    /bin/ls "$BIN" >&2
    exit 1
fi
swiftc -o "$WORK/retention_sweep" -sdk "$SDK" -suppress-warnings \
    -I "$BIN" -Xcc -fmodule-map-file="$GRDB_MODULEMAP" "$GRDB_OBJECT" \
    swift/VoiceFlowPaths.swift \
    swift/Generated/PlatformContracts.swift \
    $(/usr/bin/find swift/Captured/Store -name '*.swift' | sort) \
    $(/usr/bin/find swift/Captured/Retention -name '*.swift' | sort) \
    tests/retention_sweep/main.swift
"$WORK/retention_sweep"
