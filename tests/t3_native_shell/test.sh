#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/vf-t3-shell-unit.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
swiftc -target "$(uname -m)-apple-macos14" -swift-version 5 -parse-as-library \
  swift/Shell/VoiceFlowShellContract.swift swift/Shell/T3ShellPolicy.swift \
  swift/Shell/T3BrowserAuthentication.swift swift/Shell/VoiceFlowShellScript.swift \
  tests/t3_native_shell/contract.swift -o "$test_dir/contracts"
SHELL_TEST_SCRIPT_OUTPUT="$test_dir/bridge.js" "$test_dir/contracts"
node tests/t3_native_shell/bridge.mjs "$test_dir/bridge.js"
"${VOICE_FLOW_TEST_PYTHON:-.venv/bin/python}" tests/t3_native_shell/test_package.py
bash tests/t3_native_shell/process.sh
swiftc -target "$(uname -m)-apple-macos14" -swift-version 5 -parse-as-library \
  -emit-module -module-name VoiceFlowT3Shell swift/Shell/*.swift \
  -o "$test_dir/VoiceFlowT3Shell.swiftmodule"
python3 - <<'PY'
from pathlib import Path
source = Path('proofs/t3-native-shell/main.swift').read_text()
guard = source.index('try QALaunchIsolation.validate()')
assert guard < source.index('FileHandle.standardInput') < source.index('NSApplication.shared')
assert 'VoiceFlowPaths' not in source
assert 'AppDelegate' not in source
print('ok - isolated host fixture guards before stdin, AppKit or filesystem creation')
PY
