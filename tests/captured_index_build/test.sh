#!/bin/bash
# The six ingesters, catch-up and live. Needs GRDB and the whole Captured
# folder: nothing under swift/Captured may reach into the rest of the app
# beyond the files listed here.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "captured index build: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -f swift/Captured/CapturedService.swift ]; then
    echo "captured index build: swift/Captured/CapturedService.swift does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-captured-index-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
export VOICE_FLOW_REPO_ROOT="$REPO_ROOT"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
swiftc -o "$WORK/captured_index_build" -sdk "$SDK" -suppress-warnings \
    -I "$BIN/Modules" -L "$BIN" -lGRDB \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/CaptureRouting.swift \
    swift/CloudSyncModels.swift \
    swift/WatcherPolicy.swift \
    swift/WatcherBus.swift \
    swift/Generated/PlatformContracts.swift \
    $(find swift/Captured -name '*.swift' | sort) \
    tests/captured_index_build/main.swift \
    -framework Cocoa -framework CoreGraphics
"$WORK/captured_index_build"
