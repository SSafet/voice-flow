#!/bin/bash
# DictationStore, the dictation archive and the record sync's acting device.
# No database, so plain swiftc builds it and it runs before the Swift Package
# Manager build exists.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-dictation-store.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swiftc -o "$WORK/dictation_store" -sdk "$SDK" -suppress-warnings \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/CaptureRouting.swift \
    swift/CloudSyncModels.swift \
    swift/Captured/DictationStore.swift \
    swift/Captured/DictationArchive.swift \
    swift/Captured/RemoteDictation.swift \
    tests/dictation_store/main.swift
"$WORK/dictation_store"
