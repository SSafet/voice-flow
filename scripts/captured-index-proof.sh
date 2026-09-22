#!/bin/bash
# Build the application's catch-up reader against a caller-owned archive copy.
# It never runs live hooks, imports legacy data, starts recording, or writes
# outside the copy's index directory and the requested evidence directory.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
[ "$#" -ge 1 ] || { echo 'usage: captured-index-proof.sh <data-copy> [evidence-directory]' >&2; exit 2; }
CAPTURE_ROOT="$(python3 - "$1" <<'PY'
import os,sys
root=os.path.realpath(sys.argv[1]); live=os.path.realpath(os.path.expanduser('~/.config/voice-flow'))
if not os.path.isdir(root) or root == live or root.startswith(live+os.sep):
    raise SystemExit('An existing isolated data copy is required; refusing the daily data folder.')
print(root)
PY
)"
PROOF_DIR="${2:-$REPO_ROOT/docs/runtime-proof/captured-data/S1/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$PROOF_DIR"
WORK="$(mktemp -d /tmp/vf-captured-proof.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
snapshot() {
    python3 - "$CAPTURE_ROOT" <<'PY'
import hashlib,json,os,sys
root=sys.argv[1]; rows=[]
for base,dirs,names in os.walk(root,followlinks=False):
    for name in dirs:
        if os.path.islink(os.path.join(base,name)): raise SystemExit('Refusing archive symlink: '+os.path.join(base,name))
    if base==root: dirs[:]=[d for d in dirs if d != 'index']
    for name in sorted(names):
        path=os.path.join(base,name)
        if os.path.islink(path): raise SystemExit('Refusing archive symlink: '+path)
        with open(path,'rb') as f: data=f.read()
        rows.append([os.path.relpath(path,root),len(data),hashlib.sha256(data).hexdigest()])
print(json.dumps(sorted(rows),indent=2))
PY
}
snapshot > "$PROOF_DIR/source-before.json"
swift build -c debug --target GRDB -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
. tests/grdb_flags.sh
cp scripts/captured-index-proof.swift "$WORK/main.swift"
swiftc -o "$WORK/captured-proof" -sdk "$(xcrun --show-sdk-path)" -suppress-warnings \
    "${GRDB_LINK[@]}" swift/VoiceFlowPaths.swift swift/DisplayContext.swift \
    swift/CaptureRouting.swift swift/CloudSyncModels.swift swift/WatcherPolicy.swift \
    swift/WatcherBus.swift swift/Generated/PlatformContracts.swift \
    $(find swift/Captured -name '*.swift' | sort) "$WORK/main.swift" \
    -framework Cocoa -framework CoreGraphics
VOICE_FLOW_CONFIG_ROOT="$CAPTURE_ROOT" "$WORK/captured-proof" | tee "$PROOF_DIR/index.txt"
snapshot > "$PROOF_DIR/source-after.json"
cmp "$PROOF_DIR/source-before.json" "$PROOF_DIR/source-after.json"
python3 - "$PROOF_DIR/source-before.json" <<'PY'
import hashlib,json,sys
raw=open(sys.argv[1],'rb').read(); rows=json.loads(raw)
print(f'Source bytes unchanged: {len(rows)} files, {sum(row[1] for row in rows)} bytes, manifest SHA256 {hashlib.sha256(raw).hexdigest()}')
PY
