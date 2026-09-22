#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# This script only builds. It deliberately never opens/executes the fixture.
output=${1:?Pass a new absolute output directory under /tmp}
output=$(python3 - "$output" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
if not path.is_absolute():
    raise SystemExit('Build directory must be absolute.')
resolved = path.resolve()
temporary = Path('/tmp').resolve()
if temporary not in resolved.parents:
    raise SystemExit('Build directory must remain inside /tmp after resolving aliases.')
print(resolved)
PY
)
if [[ -e "$output" ]]; then printf 'Output already exists; choose a new path.\n' >&2; exit 64; fi
mkdir -m 700 "$output"
bundle="$output/Voice Flow T3 Shell QA.app"
mkdir -p "$bundle/Contents/MacOS"
cp proofs/t3-native-shell/Info.plist "$bundle/Contents/Info.plist"
swiftc -target "$(uname -m)-apple-macos14" -swift-version 5 -DVOICE_FLOW_QA \
  -parse-as-library swift/QALaunchIsolation.swift swift/Shell/*.swift \
  proofs/t3-native-shell/main.swift -o "$bundle/Contents/MacOS/t3-shell-fixture"
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
shasum -a 256 "$bundle/Contents/MacOS/t3-shell-fixture" > "$output/binary-sha256.txt"
git rev-parse HEAD > "$output/source-head.txt"
git status --porcelain > "$output/source-status.txt"
printf '%s\n' "$bundle"
