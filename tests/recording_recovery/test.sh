#!/bin/bash
# RecordingRecovery: the undelivered WAVs, the dictations they become, and
# what is kept when there is nothing to transcribe. Needs GRDB and
# DictationStore, so it is built the way the app is built.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "recording recovery: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -d swift/Captured/Store ]; then
    echo "recording recovery: swift/Captured/Store does not exist yet — S1 has not landed on this branch" >&2
    exit 1
fi
if [ ! -f swift/Captured/RecordingRecovery.swift ]; then
    echo "recording recovery: swift/Captured/RecordingRecovery.swift does not exist yet" >&2
    exit 1
fi
if [ ! -f swift/Captured/DictationStore.swift ]; then
    echo "recording recovery: swift/Captured/DictationStore.swift does not exist yet — S1 has not landed" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-recording-recovery.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
GRDB_OBJECT="$(/usr/bin/find "$BIN" -maxdepth 1 -name 'GRDB.o' -print -quit)"
GRDB_MODULEMAP="$(/usr/bin/find "$REPO_ROOT/.build" -path '*GRDBSQLite*' -name 'module.modulemap' -print -quit)"
if [ -z "$GRDB_OBJECT" ] || [ -z "$GRDB_MODULEMAP" ]; then
    echo "recording recovery: GRDB's object file or GRDBSQLite's module map is not where this runner looks." >&2
    /bin/ls "$BIN" >&2
    exit 1
fi
swiftc -o "$WORK/recording_recovery" -sdk "$SDK" -suppress-warnings \
    -I "$BIN" -Xcc -fmodule-map-file="$GRDB_MODULEMAP" "$GRDB_OBJECT" \
    swift/VoiceFlowPaths.swift \
    swift/Generated/PlatformContracts.swift \
    swift/CaptureRouting.swift \
    swift/CloudSyncModels.swift \
    $(/usr/bin/find swift/Captured/Store -name '*.swift' | sort) \
    swift/Captured/DictationStore.swift \
    swift/Captured/DictationArchive.swift \
    swift/Captured/RemoteDictation.swift \
    swift/Captured/RecordingRecovery.swift \
    tests/recording_recovery/main.swift
"$WORK/recording_recovery"
