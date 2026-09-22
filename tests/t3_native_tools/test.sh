#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d /tmp/vf-t3-native-tools.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
# A reviewed checkout's dependency outputs may be reused read-only. No app binary is run.
DEPS="${VOICE_FLOW_DEPENDENCY_ROOT:-$ROOT}"
if [ "$DEPS" = "$ROOT" ]; then
  swift build -c debug --target MCP -j 2 -Xswiftc -suppress-warnings >/dev/null
  swift build -c debug --target GRDB -j 2 -Xswiftc -suppress-warnings >/dev/null
fi
BIN="$(cd "$DEPS" && swift build -c debug --show-bin-path)"
MAP="$DEPS/.build/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap"
# Compile the real ComputerControl implementation, excluding the unrelated agent runtime.
python3 - "$WORK/ComputerControl.swift" <<'PY'
import pathlib,sys
source=pathlib.Path('swift/Agent.swift').read_text()
assert source.count('final class ComputerControl {') == 1
pathlib.Path(sys.argv[1]).write_text('import AppKit\n'+source[source.index('final class ComputerControl {'):])
PY
swiftc -parse-as-library -swift-version 5 -suppress-warnings -I "$BIN" -Xcc "-fmodule-map-file=$MAP" \
  "$BIN/MCP.o" "$BIN/SystemPackage.o" "$BIN/CSystem.o" "$BIN/EventSource.o" "$BIN/Logging.o" "$BIN/GRDB.o" \
  swift/VoiceFlowPaths.swift swift/DisplayContext.swift swift/CaptureRouting.swift \
  swift/CloudSyncModels.swift swift/WatcherPolicy.swift swift/WatcherBus.swift swift/AgentSecretPolicy.swift \
  swift/ImageUtils.swift swift/Generated/PlatformContracts.swift \
  $(find swift/Captured -name '*.swift' | sort) \
  swift/Inbox.swift swift/MCP.swift swift/MCPHTTPHost.swift swift/MCPToolCancellation.swift \
  swift/MCPCapturedCatalog.swift swift/MCPCapturedReader.swift swift/MCPOverlayScope.swift \
  swift/NativeTools/T3NativeToolService.swift swift/NativeTools/T3NativeToolCatalog.swift \
  swift/NativeTools/T3NativeToolMCP.swift swift/NativeTools/T3NativeToolPrimitives.swift \
  "$WORK/ComputerControl.swift" tests/t3_native_tools/main.swift \
  -framework Cocoa -framework CoreGraphics -o "$WORK/proof"
"$WORK/proof"
