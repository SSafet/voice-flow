#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN_ROOT="$(mktemp -d /tmp/vf-qa-launch-guard.XXXXXX)"
trap 'rm -rf "$RUN_ROOT"' EXIT
swiftc -suppress-warnings "$REPO_ROOT/swift/QALaunchIsolation.swift" \
    "$REPO_ROOT/tests/qa_launch_isolation/main.swift" -o "$RUN_ROOT/probe"
"$RUN_ROOT/probe"
python3 - "$REPO_ROOT/swift/main.swift" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text()
guard=source.index('try QALaunchIsolation.validate()')
assert guard < source.index('NSApplication.shared')
assert guard < source.index('AppDelegate()')
assert 'VoiceFlowPaths' not in source[:guard]
assert 'vflog(' not in source[:guard]
print('ok - QA refusal precedes AppKit application/delegate, paths and logging')
PY
