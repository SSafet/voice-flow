#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/vf-t3-native-input.XXXXXX")
trap 'rm -rf "$work"' EXIT
export VOICE_FLOW_CONFIG_ROOT="$work/config"
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"
# Optional read-only reuse of a matching dependency build; never share a writable
# build directory or invoke the other checkout's application.
if [[ -n ${VOICE_FLOW_GRDB_BUILD_ROOT:-} ]]; then
  cmp Package.resolved "$VOICE_FLOW_GRDB_BUILD_ROOT/Package.resolved"
  dependency_root="$VOICE_FLOW_GRDB_BUILD_ROOT"
  bin="$dependency_root/.build/out/Products/Debug"
else
  swift build -c debug --target GRDB -Xswiftc -suppress-warnings >/dev/null
  dependency_root="$PWD"
  bin="$(swift build -c debug --show-bin-path)"
fi
modulemap=$(find "$dependency_root/.build" -path '*GRDBSQLite*' -name module.modulemap -print -quit)
if [[ -f "$bin/GRDB.o" ]]; then
  grdb=(-I "$bin" -Xcc "-fmodule-map-file=$modulemap" "$bin/GRDB.o")
else
  grdb=(-I "$bin/Modules" -L "$bin" -lGRDB)
fi
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14" \
  -o "$work/native-input" "${grdb[@]}" \
  swift/VoiceFlowPaths.swift swift/DisplayContext.swift swift/CaptureRouting.swift \
  swift/Capture.swift swift/ScreenCapture.swift swift/Annotation.swift swift/PendingAudio.swift \
  swift/CloudSyncModels.swift swift/WatcherPolicy.swift swift/WatcherBus.swift \
  swift/AgentSecretPolicy.swift swift/ImageUtils.swift swift/Generated/PlatformContracts.swift \
  swift/Shell/VoiceFlowShellContract.swift swift/Shell/ShellInputCustody.swift swift/Shell/ShellCaptureMarks.swift swift/ShellCapturedInput.swift \
  $(find swift/Captured -name '*.swift' | sort) tests/t3_native_input/main.swift \
  -framework Cocoa -framework CoreGraphics -framework ScreenCaptureKit
"$work/native-input"
swiftc swift/CaptureRouting.swift tests/capture_routing/main.swift -o "$work/routing"
"$work/routing"
python3 tests/t3_native_input/test_wiring.py
