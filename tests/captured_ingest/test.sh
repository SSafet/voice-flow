#!/bin/bash
# The six ingesters, catch-up and live. Needs GRDB and the whole Captured
# folder: nothing under swift/Captured may reach into the rest of the app
# beyond the files listed here.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
if [ ! -f Package.swift ]; then
    echo "captured ingest: Package.swift is missing — K8 has not landed on this branch yet" >&2
    exit 1
fi
if [ ! -d swift/Captured/Ingesters ]; then
    echo "captured ingest: swift/Captured/Ingesters does not exist yet" >&2
    exit 1
fi
SDK="${XCODE_SDK:-$(xcrun --show-sdk-path)}"
WORK="$(mktemp -d /tmp/vf-captured-ingest.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
# The flags that link a suite against the package's GRDB, for either products layout.
. tests/grdb_flags.sh
swiftc -o "$WORK/captured_ingest" -sdk "$SDK" -suppress-warnings \
    "${GRDB_LINK[@]}" \
    swift/VoiceFlowPaths.swift \
    swift/DisplayContext.swift \
    swift/CaptureRouting.swift \
    swift/CloudSyncModels.swift \
    swift/WatcherPolicy.swift \
    swift/WatcherBus.swift \
    swift/Generated/PlatformContracts.swift \
    $(find swift/Captured -name '*.swift' | sort) \
    tests/captured_ingest/main.swift \
    -framework Cocoa -framework CoreGraphics
"$WORK/captured_ingest"
