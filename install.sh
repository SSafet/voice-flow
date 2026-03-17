#!/bin/bash
# Install Voice Flow to /Applications
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Voice Flow"
APP_DEST="/Applications/$APP_NAME.app"
VENV="$PROJECT_DIR/.venv"

echo "Installing $APP_NAME..."

# ── preflight ──────────────────────────────────────────
if [ ! -d "$VENV" ]; then
    echo "Error: No .venv found. Run 'cd $PROJECT_DIR && uv sync' first."
    exit 1
fi

if ! command -v swiftc &>/dev/null; then
    echo "Error: swiftc not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

# ── remove old installation ────────────────────────────
rm -rf "$APP_DEST"

# ── copy the .app template ─────────────────────────────
cp -R "$PROJECT_DIR/$APP_NAME.app" "$APP_DEST"

# Remove the old bash launcher (replaced by compiled Swift binary)
rm -f "$APP_DEST/Contents/MacOS/voice-flow"

# ── copy assets into bundle Resources ──────────────────
cp "$PROJECT_DIR/assets/StatusBarIconTemplate@2x.png" "$APP_DEST/Contents/Resources/" 2>/dev/null || true
cp "$PROJECT_DIR/assets/StatusBarIconTemplate.png"     "$APP_DEST/Contents/Resources/" 2>/dev/null || true
cp "$PROJECT_DIR/assets/icon.icns"                     "$APP_DEST/Contents/Resources/" 2>/dev/null || true

# Write project directory path into bundle for BackendBridge
echo -n "$PROJECT_DIR" > "$APP_DEST/Contents/Resources/project_dir.txt"

# ── compile Swift ──────────────────────────────────────
echo "  Compiling Swift..."
SDK="$(xcrun --show-sdk-path)"

swiftc -o "$APP_DEST/Contents/MacOS/voice-flow" \
    "$PROJECT_DIR"/swift/*.swift \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework ApplicationServices \
    -framework Accelerate \
    -framework ScreenCaptureKit \
    -sdk "$SDK" \
    -O \
    -suppress-warnings

chmod +x "$APP_DEST/Contents/MacOS/voice-flow"
echo "  ✓ Swift binary compiled"

# ── codesign ───────────────────────────────────────────
codesign --force --sign - --identifier "com.voiceflow.app" \
    "$APP_DEST/Contents/MacOS/voice-flow"
codesign --force --deep --sign - "$APP_DEST"

echo ""
echo "✓ Installed to $APP_DEST"
echo ""
echo "Launch: open /Applications/Voice\\ Flow.app"
