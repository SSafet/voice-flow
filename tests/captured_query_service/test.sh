#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
WORK="$(mktemp -d /tmp/vf-captured-query.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug --target GRDB -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
. tests/grdb_flags.sh
swiftc -whole-module-optimization -num-threads 2 -o "$WORK/captured_query" -sdk "$(xcrun --show-sdk-path)" -suppress-warnings \
  "${GRDB_LINK[@]}" \
  swift/VoiceFlowPaths.swift swift/DisplayContext.swift swift/CaptureRouting.swift \
  swift/CloudSyncModels.swift swift/WatcherPolicy.swift swift/WatcherBus.swift \
  swift/AgentSecretPolicy.swift swift/ImageUtils.swift swift/Generated/PlatformContracts.swift \
  $(find swift/Captured -name '*.swift' | sort) \
  tests/captured_query_service/main.swift -framework Cocoa -framework CoreGraphics
"$WORK/captured_query"
