#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
WORK="$(mktemp -d /tmp/vf-native-mcp-sdk.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$WORK/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
export VOICE_FLOW_QA_PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
swift build -c debug --target MCP -j 2 -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
swiftc -parse-as-library -D VOICE_FLOW_QA -suppress-warnings -I "$BIN" \
  "$BIN/MCP.o" "$BIN/SystemPackage.o" "$BIN/CSystem.o" "$BIN/EventSource.o" "$BIN/Logging.o" \
  swift/VoiceFlowPaths.swift swift/QAControl.swift swift/AgentSecretPolicy.swift swift/Inbox.swift swift/LocalAPI.swift \
  swift/MCP.swift swift/MCPHTTPHost.swift swift/MCPToolCancellation.swift swift/MCPCapturedCatalog.swift swift/MCPOverlayScope.swift \
  tests/native_mcp_sdk/main.swift -o "$WORK/proof"
"$WORK/proof"
