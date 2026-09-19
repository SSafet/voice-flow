#!/bin/bash
# CapturedHealth: the one status object, built from the index and the sweeper.
# Needs GRDB, and the recording state it reads is RecordingRecovery's.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "captured health: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -d swift/Captured/Store ] || [ ! -d swift/Captured/Retention ]; then
    echo "captured health: the store or the retention folder does not exist yet — S1 and S5 task 2 first" >&2
    exit 1
fi
if [ ! -f swift/Captured/CapturedHealth.swift ] || [ ! -f swift/Captured/RecordingRecovery.swift ]; then
    echo "captured health: CapturedHealth.swift or RecordingRecovery.swift does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-captured-health.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
GRDB_OBJECT="$(/usr/bin/find "$BIN" -maxdepth 1 -name 'GRDB.o' -print -quit)"
GRDB_MODULEMAP="$(/usr/bin/find "$REPO_ROOT/.build" -path '*GRDBSQLite*' -name 'module.modulemap' -print -quit)"
if [ -z "$GRDB_OBJECT" ] || [ -z "$GRDB_MODULEMAP" ]; then
    echo "captured health: GRDB's object file or GRDBSQLite's module map is not where this runner looks." >&2
    /bin/ls "$BIN" >&2
    exit 1
fi
swiftc -o "$WORK/captured_health" -sdk "$SDK" -suppress-warnings \
    -I "$BIN" -Xcc -fmodule-map-file="$GRDB_MODULEMAP" "$GRDB_OBJECT" \
    swift/VoiceFlowPaths.swift \
    swift/Generated/PlatformContracts.swift \
    swift/CaptureRouting.swift \
    swift/CloudSyncModels.swift \
    $(/usr/bin/find swift/Captured/Store -name '*.swift' | sort) \
    $(/usr/bin/find swift/Captured/Retention -name '*.swift' | sort) \
    swift/Captured/DictationStore.swift \
    swift/Captured/DictationArchive.swift \
    swift/Captured/RemoteDictation.swift \
    swift/Captured/RecordingRecovery.swift \
    swift/Captured/CapturedHealth.swift \
    tests/captured_health/main.swift
"$WORK/captured_health"
