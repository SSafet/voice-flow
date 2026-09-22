#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/vf-t3-process.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
bundle="$test_dir/Fixture.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources/T3/client" "$bundle/Contents/Resources/T3/node_modules" "$bundle/Contents/Resources/T3/resource-monitor"
swiftc -target "$(uname -m)-apple-macos14" -swift-version 5 -parse-as-library tests/t3_native_shell/process_fixture.swift -o "$bundle/Contents/Resources/T3/t3"
cp "$bundle/Contents/Resources/T3/t3" "$bundle/Contents/MacOS/fixture"
codesign --force --sign - "$bundle/Contents/Resources/T3/t3"
python3 - "$bundle" <<'PY'
import hashlib, json, plistlib, sys
from pathlib import Path
bundle = Path(sys.argv[1])
runtime = bundle / 'Contents/Resources/T3'
(bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.voiceflow.tests.t3-process', 'CFBundleExecutable': 'fixture', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1'}))
(runtime / 'client/index.html').write_text('<!doctype html><title>Process fixture</title>')
(runtime / 'client/app.js').write_text('// sealed fixture asset')
(runtime / 'node_modules/fixture').write_text('fixture')
(runtime / 'resource-monitor/fixture').write_text('fixture')
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
(runtime / 'voiceflow-archive-receipt.json').write_text(json.dumps({'archiveSha256': 'a'*64, 'executableSha256': digest(runtime/'t3'), 'clientIndexSha256': digest(runtime/'client/index.html')}))
PY
codesign --force --sign - "$bundle"
codesign --verify --deep --strict "$bundle"
swiftc -target "$(uname -m)-apple-macos14" -swift-version 5 -parse-as-library swift/Shell/T3ShellPolicy.swift swift/Shell/T3NativeAuthority.swift swift/Shell/T3EnvironmentProcess.swift tests/t3_native_shell/process.swift -o "$test_dir/process-tests"
T3CODE_HOME=/invalid-ambient-test-home VITE_DEV_SERVER_URL=https://invalid.example NODE_OPTIONS=--invalid-fixture-option OPENROUTER_API_KEY=synthetic-fixture-key "$test_dir/process-tests" "$test_dir"
