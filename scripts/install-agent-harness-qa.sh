#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Voice Flow QA"
APP_DEST="${VOICE_FLOW_QA_APP_DEST:-/Applications/$APP_NAME.app}"
STAGE="$(mktemp -d /tmp/voice-flow-qa-install.XXXXXX)"
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

"$PROJECT_DIR/scripts/prepare-opencode-runtime.sh" "$RUNTIME_STAGE/OpenCode"
cp -R "$PROJECT_DIR/Voice Flow.app" "$STAGED_APP"
rm -f "$STAGED_APP/Contents/MacOS/voice-flow"

plutil -replace CFBundleDisplayName -string "$APP_NAME" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$STAGED_APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.voiceflow.app.qa" "$STAGED_APP/Contents/Info.plist"

mkdir -p "$STAGED_APP/Contents/Resources/Runtime/OpenCode" \
    "$STAGED_APP/Contents/Resources/QA"
cp "$RUNTIME_STAGE/OpenCode/opencode" \
    "$STAGED_APP/Contents/Resources/Runtime/OpenCode/opencode"
cp "$RUNTIME_STAGE/OpenCode/versions.json" \
    "$STAGED_APP/Contents/Resources/Runtime/OpenCode/versions.json"
cp "$PROJECT_DIR/tests/capabilities.json" \
    "$STAGED_APP/Contents/Resources/QA/capabilities.json"
chmod 755 "$STAGED_APP/Contents/Resources/Runtime/OpenCode/opencode"
printf '%s' "$PROJECT_DIR" > "$STAGED_APP/Contents/Resources/project_dir.txt"
rm -rf "$STAGED_APP/Contents/Resources/voice_flow"
cp -R "$PROJECT_DIR/voice_flow" "$STAGED_APP/Contents/Resources/voice_flow"
find "$STAGED_APP/Contents/Resources/voice_flow" -type d -name __pycache__ \
    -prune -exec rm -rf {} +

XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [ ! -d "$XCODE_SDK" ]; then XCODE_SDK="$(xcrun --show-sdk-path)"; fi
mkdir -p "$STAGE/module-cache"
SWIFT_MODULECACHE_PATH="$STAGE/module-cache" CLANG_MODULE_CACHE_PATH="$STAGE/module-cache" \
swiftc -o "$STAGED_APP/Contents/MacOS/voice-flow" \
    "$PROJECT_DIR"/swift/*.swift -D VOICE_FLOW_QA \
    -framework Cocoa -framework AVFoundation -framework CoreGraphics \
    -framework ApplicationServices -framework Accelerate -framework Security \
    -framework ScreenCaptureKit -lsqlite3 -sdk "$XCODE_SDK" -O -suppress-warnings
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
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$STAGED_APP/Contents/Resources/Runtime/OpenCode/opencode"
    codesign --force --sign - --identifier "com.voiceflow.app.qa" \
        "$STAGED_APP/Contents/MacOS/voice-flow"
else
    codesign --force --timestamp=none --sign "$SIGN_ID" \
        "$STAGED_APP/Contents/Resources/Runtime/OpenCode/opencode"
    codesign --force --timestamp=none --sign "$SIGN_ID" \
        --identifier "com.voiceflow.app.qa" "$STAGED_APP/Contents/MacOS/voice-flow"
fi
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
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --deep --sign - "$STAGED_APP"
else
    codesign --force --deep --timestamp=none --sign "$SIGN_ID" "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"

mkdir -p "$(dirname "$APP_DEST")"
BACKUP="$STAGE/previous.app"
if [ -e "$APP_DEST" ]; then mv "$APP_DEST" "$BACKUP"; fi
if ! mv "$STAGED_APP" "$APP_DEST"; then
    if [ -e "$BACKUP" ]; then mv "$BACKUP" "$APP_DEST"; fi
    exit 1
fi
rm -rf "$BACKUP"
echo "QA app installed at $APP_DEST"
