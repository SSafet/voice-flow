#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d /tmp/vf-native-mcp-captured.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
swift build -c debug --target MCP -j 2 -Xswiftc -suppress-warnings >/dev/null
swift build -c debug --target GRDB -j 2 -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
. tests/grdb_flags.sh
python3 - "$WORK/main.swift" <<'PY'
import pathlib,sys
source=pathlib.Path('tests/captured_query_service/main.swift').read_text()
extra=pathlib.Path('tests/native_mcp_sdk/captured-assertions.swift').read_text()
source=source.replace('if failures.isEmpty {',extra+'\nif failures.isEmpty {')
pathlib.Path(sys.argv[1]).write_text('import MCP\n'+source)
PY
swiftc -whole-module-optimization -num-threads 2 -suppress-warnings -o "$WORK/proof" \
  "${GRDB_LINK[@]}" "$BIN/MCP.o" "$BIN/SystemPackage.o" "$BIN/CSystem.o" "$BIN/EventSource.o" "$BIN/Logging.o" \
  swift/VoiceFlowPaths.swift swift/DisplayContext.swift swift/CaptureRouting.swift \
  swift/CloudSyncModels.swift swift/WatcherPolicy.swift swift/WatcherBus.swift \
  swift/AgentSecretPolicy.swift swift/ImageUtils.swift swift/Generated/PlatformContracts.swift \
  swift/MCP.swift swift/MCPHTTPHost.swift swift/MCPToolCancellation.swift swift/MCPCapturedCatalog.swift swift/MCPCapturedReader.swift \
  $(find swift/Captured -name '*.swift' | sort) "$WORK/main.swift" -framework Cocoa -framework CoreGraphics
"$WORK/proof"
