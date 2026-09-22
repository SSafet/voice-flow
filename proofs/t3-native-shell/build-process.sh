#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Build and sign only. The coordinator separately proves envless refusal, then
# launches this exact binary with a private QA root and port. Never opens a GUI.
archive=${1:?Pass the reviewed complete CLI archive}
digest=${2:?Pass its reviewed SHA256}
output=${3:?Pass a new output directory under /tmp}
output=$(python3 - "$output" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
resolved = path.resolve()
if not path.is_absolute() or Path('/tmp').resolve() not in resolved.parents:
    raise SystemExit('A new absolute build directory under /tmp is required.')
print(resolved)
PY
)
if [[ -e "$output" ]]; then exit 64; fi
mkdir -m 700 "$output"
bundle="$output/Voice Flow T3 Process QA.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp proofs/t3-native-shell/Info.plist "$bundle/Contents/Info.plist"
"${VOICE_FLOW_TEST_PYTHON:-.venv/bin/python}" scripts/stage-t3-shell-runtime.py --archive "$archive" --sha256 "$digest" --destination "$bundle/Contents/Resources/T3" > "$output/staging-receipt.json"
swiftc -target "$(uname -m)-apple-macos14" -swift-version 5 -DVOICE_FLOW_QA -parse-as-library \
  swift/QALaunchIsolation.swift swift/Shell/T3ShellPolicy.swift swift/Shell/T3BrowserAuthentication.swift \
  swift/Shell/T3EnvironmentProcess.swift proofs/t3-native-shell/process-main.swift \
  -o "$bundle/Contents/MacOS/t3-shell-fixture"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
shasum -a 256 "$bundle/Contents/MacOS/t3-shell-fixture" > "$output/binary-sha256.txt"
git rev-parse HEAD > "$output/source-head.txt"
git status --porcelain > "$output/source-status.txt"
printf '%s\n' "$bundle"
