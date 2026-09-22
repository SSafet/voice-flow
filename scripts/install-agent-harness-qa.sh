#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Voice Flow QA"
APP_DEST="${VOICE_FLOW_QA_APP_DEST:-/Applications/$APP_NAME.app}"
T3_ARCHIVE="${VOICE_FLOW_T3_ARCHIVE:-}"
PYTHON="${VOICE_FLOW_BUILD_PYTHON:-$PROJECT_DIR/.venv/bin/python}"
if [ -n "$T3_ARCHIVE" ]; then
    : "${VOICE_FLOW_T3_ARCHIVE_SHA256:?Set the reviewed T3 archive SHA256.}"
    : "${VOICE_FLOW_QA_APP_DEST:?T3 QA requires an explicit new isolated app destination.}"
    # T3 QA is a build artifact, never an installation over the daily app.
    APP_DEST="$("$PYTHON" - "$APP_DEST" <<'PY'
from pathlib import Path
import sys
destination = Path(sys.argv[1])
if not destination.is_absolute() or destination.suffix != '.app':
    raise SystemExit('T3 QA destination must be an absolute .app path.')
if destination.exists() or destination.is_symlink():
    raise SystemExit('T3 QA destination must be new.')
resolved = destination.resolve()
for root in [Path('/Applications'), Path.home() / 'Applications',
             Path.home() / '.config/voice-flow', Path.home() / '.t3']:
    root = root.resolve()
    if resolved == root or root in resolved.parents or resolved in root.parents:
        raise SystemExit('T3 QA destination cannot be an installed-app or live-data path.')
print(resolved)
PY
)"
    mkdir -p "$(dirname "$APP_DEST")"
    STAGE="$(mktemp -d "$(dirname "$APP_DEST")/.voice-flow-qa-build.XXXXXX")"
else
    STAGE="$(mktemp -d /tmp/voice-flow-qa-install.XXXXXX)"
fi
RUNTIME_STAGE="$STAGE/runtime"
STAGED_APP="$STAGE/$APP_NAME.app"
cleanup() {
    status=$?
    trap - EXIT
    rm -rf "$STAGE"
    exit "$status"
}
trap cleanup EXIT

[ -d "$PROJECT_DIR/.venv" ] || {
    echo "Error: .venv is missing; run uv sync first." >&2
    exit 1
}

if [ -n "$T3_ARCHIVE" ]; then
    "$PYTHON" "$PROJECT_DIR/scripts/stage-t3-shell-runtime.py" \
        --archive "$T3_ARCHIVE" --sha256 "$VOICE_FLOW_T3_ARCHIVE_SHA256" \
        --destination "$STAGE/T3" --require-native
else
    "$PROJECT_DIR/scripts/prepare-ripgrep-runtime.sh" "$RUNTIME_STAGE/ripgrep"
fi
"$PROJECT_DIR/scripts/prepare-opencode-runtime.sh" "$RUNTIME_STAGE/OpenCode"
cp -R "$PROJECT_DIR/Voice Flow.app" "$STAGED_APP"
rm -f "$STAGED_APP/Contents/MacOS/voice-flow"

plutil -replace CFBundleDisplayName -string "$APP_NAME" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.voiceflow.app.qa" "$STAGED_APP/Contents/Info.plist"

mkdir -p "$STAGED_APP/Contents/Resources/QA"
cp "$PROJECT_DIR/tests/capabilities.json" \
    "$STAGED_APP/Contents/Resources/QA/capabilities.json"
if [ -n "$T3_ARCHIVE" ]; then
    rm -rf "$STAGED_APP/Contents/Resources/Runtime" "$STAGED_APP/Contents/Resources/T3"
    mv "$STAGE/T3" "$STAGED_APP/Contents/Resources/T3"
    # The T3 driver verifies the release hash, so retain OpenCode's original
    # signed bytes instead of applying the legacy installer re-signing step.
    mkdir -p "$STAGED_APP/Contents/Resources/Runtime"
    cp -R "$RUNTIME_STAGE/OpenCode" "$STAGED_APP/Contents/Resources/Runtime/OpenCode"
else
    mkdir -p "$STAGED_APP/Contents/Resources/Runtime/OpenCode"
    cp "$RUNTIME_STAGE/OpenCode/opencode" \
        "$STAGED_APP/Contents/Resources/Runtime/OpenCode/opencode"
    cp "$RUNTIME_STAGE/OpenCode/versions.json" \
        "$STAGED_APP/Contents/Resources/Runtime/OpenCode/versions.json"
    chmod 755 "$STAGED_APP/Contents/Resources/Runtime/OpenCode/opencode"
    mkdir -p "$STAGED_APP/Contents/Resources/Runtime/ripgrep"
    cp "$RUNTIME_STAGE/ripgrep/rg" "$STAGED_APP/Contents/Resources/Runtime/ripgrep/rg"
    cp "$RUNTIME_STAGE/ripgrep/versions.json" \
        "$STAGED_APP/Contents/Resources/Runtime/ripgrep/versions.json"
    chmod 755 "$STAGED_APP/Contents/Resources/Runtime/ripgrep/rg"
fi
printf '%s' "$PROJECT_DIR" > "$STAGED_APP/Contents/Resources/project_dir.txt"
rm -rf "$STAGED_APP/Contents/Resources/voice_flow"
cp -R "$PROJECT_DIR/voice_flow" "$STAGED_APP/Contents/Resources/voice_flow"
find "$STAGED_APP/Contents/Resources/voice_flow" -type d -name __pycache__ \
    -prune -exec rm -rf {} +

# The launch-time contract self-check reads these (K8). They are data, not
# code, and they are what the About window reports on.
rm -rf "$STAGED_APP/Contents/Resources/ContractFixtures"
cp -R "$PROJECT_DIR/contract-fixtures" "$STAGED_APP/Contents/Resources/ContractFixtures"
cp "$PROJECT_DIR/thread-protocol.lock" "$STAGED_APP/Contents/Resources/thread-protocol.lock"

# Swift Package Manager, from a snapshot of the package, so that another
# session editing Swift files during this build cannot make an incoherent
# binary. The snapshot needs the manifest and its resolution beside the
# sources; the contract fixtures are not in it, because they are data the
# bundle carries — copied straight into Contents/Resources above, where the
# launch-time contract self-check reads them (K8 task 9) — and not sources
# this target compiles.
cp "$PROJECT_DIR/Package.swift" "$PROJECT_DIR/Package.resolved" "$STAGE/"
cp -R "$PROJECT_DIR/swift" "$STAGE/swift"
QA_OPTIMIZATION_FLAGS=()
if [ -n "${VOICE_FLOW_QA_OPTIMIZATION:-}" ]; then
    QA_OPTIMIZATION_FLAGS=(-Xswiftc "$VOICE_FLOW_QA_OPTIMIZATION")
fi
swift build -c release --package-path "$STAGE" \
    -Xswiftc -DVOICE_FLOW_QA -Xswiftc -suppress-warnings \
    ${QA_OPTIMIZATION_FLAGS[@]+"${QA_OPTIMIZATION_FLAGS[@]}"}
cp "$(swift build --package-path "$STAGE" -c release --show-bin-path)/voice-flow" \
    "$STAGED_APP/Contents/MacOS/voice-flow"
chmod 755 "$STAGED_APP/Contents/MacOS/voice-flow"

SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -z "$SIGN_ID" ]; then
    [ "${VF_ADHOC:-}" = "1" ] || {
        echo "No stable Developer ID identity. Set VF_ADHOC=1 only for an isolated test run." >&2
        exit 1
    }
    SIGN_ID="-"
fi
SIGN_ARGS=(--force --timestamp=none --sign "$SIGN_ID")
if [ -z "$T3_ARCHIVE" ]; then
    codesign "${SIGN_ARGS[@]}" \
        "$STAGED_APP/Contents/Resources/Runtime/OpenCode/opencode"
    codesign "${SIGN_ARGS[@]}" \
        "$STAGED_APP/Contents/Resources/Runtime/ripgrep/rg"
    RUNTIME_ARCH="$(uname -m)"
    [ "$RUNTIME_ARCH" = "x86_64" ] || RUNTIME_ARCH="arm64"
    SOURCE_RUNTIME_SHA="$(plutil -extract "assets.$RUNTIME_ARCH.binarySHA256" raw \
        "$STAGED_APP/Contents/Resources/Runtime/OpenCode/versions.json")"
    RUNTIME_VERSION="$(plutil -extract version raw \
        "$STAGED_APP/Contents/Resources/Runtime/OpenCode/versions.json")"
    INSTALLED_RUNTIME_SHA="$(shasum -a 256 \
        "$STAGED_APP/Contents/Resources/Runtime/OpenCode/opencode" | awk '{print $1}')"
    printf '{"version":"%s","architecture":"%s","sourceBinarySHA256":"%s","installedBinarySHA256":"%s"}\n' \
        "$RUNTIME_VERSION" "$RUNTIME_ARCH" "$SOURCE_RUNTIME_SHA" "$INSTALLED_RUNTIME_SHA" \
        > "$STAGED_APP/Contents/Resources/Runtime/OpenCode/installed.json"
fi
codesign "${SIGN_ARGS[@]}" --identifier "com.voiceflow.app.qa" \
    "$STAGED_APP/Contents/MacOS/voice-flow"
# The reviewed archive is already signed. Re-signing its nested executable
# changes its hash and invalidates the native shell's provenance receipt.
DEEP_SIGN=()
if [ -z "$T3_ARCHIVE" ]; then DEEP_SIGN=(--deep); fi
codesign "${SIGN_ARGS[@]}" ${DEEP_SIGN[@]+"${DEEP_SIGN[@]}"} "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

mkdir -p "$(dirname "$APP_DEST")"
if [ -n "$T3_ARCHIVE" ]; then
    # Same exclusive publication as runtime staging; no race can replace an app.
    "$PYTHON" - "$PROJECT_DIR/scripts/stage-t3-shell-runtime.py" "$STAGED_APP" "$APP_DEST" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('stage_t3', sys.argv[1])
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)
app = Path(sys.argv[2])
resources = app / 'Contents/Resources'
receipt = json.loads((resources / 'T3/voiceflow-archive-receipt.json').read_text())
opencode = json.loads((resources / 'Runtime/OpenCode/installed.json').read_text())
for executable, expected in [(resources / 'T3/t3', receipt['executableSha256']),
                             (resources / 'Runtime/OpenCode/opencode', opencode['sourceBinarySHA256'])]:
    if stage.digest(executable) != expected:
        raise SystemExit('Signing changed a reviewed runtime; the QA app was not published.')
stage.publish_new_directory(app, Path(sys.argv[3]))
PY
    echo "T3 native QA app built at $APP_DEST (not launched)"
    exit 0
fi
BACKUP="$STAGE/previous.app"
if [ -e "$APP_DEST" ]; then mv "$APP_DEST" "$BACKUP"; fi
if ! mv "$STAGED_APP" "$APP_DEST"; then
    if [ -e "$BACKUP" ]; then mv "$BACKUP" "$APP_DEST"; fi
    exit 1
fi
rm -rf "$BACKUP"
echo "QA app installed at $APP_DEST"
