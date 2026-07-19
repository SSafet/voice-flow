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
"$PROJECT_DIR/uninstall.sh"

# ── copy the .app template ─────────────────────────────
cp -R "$PROJECT_DIR/$APP_NAME.app" "$APP_DEST"

# Remove the old bash launcher (replaced by compiled Swift binary)
rm -f "$APP_DEST/Contents/MacOS/voice-flow"

# ── copy assets into bundle Resources ──────────────────
cp "$PROJECT_DIR/assets/StatusBarIconTemplate@2x.png" "$APP_DEST/Contents/Resources/" 2>/dev/null || true
cp "$PROJECT_DIR/assets/StatusBarIconTemplate.png"     "$APP_DEST/Contents/Resources/" 2>/dev/null || true
cp "$PROJECT_DIR/assets/icon.icns"                     "$APP_DEST/Contents/Resources/" 2>/dev/null || true

# Write project directory path into bundle (used to locate .venv).
# VF_PROJECT_DIR overrides it when compiling from a throwaway snapshot
# (e.g. a git worktree) so the app keeps pointing at the real repo.
echo -n "${VF_PROJECT_DIR:-$PROJECT_DIR}" > "$APP_DEST/Contents/Resources/project_dir.txt"

# Bundle Python source so the app is self-contained
rm -rf "$APP_DEST/Contents/Resources/voice_flow"
cp -R "$PROJECT_DIR/voice_flow" "$APP_DEST/Contents/Resources/voice_flow"

# ── compile Swift ──────────────────────────────────────
echo "  Compiling Swift..."
XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [ -d "$XCODE_SDK" ]; then
    SDK="$XCODE_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi

swiftc -o "$APP_DEST/Contents/MacOS/voice-flow" \
    "$PROJECT_DIR"/swift/*.swift \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework ApplicationServices \
    -framework Accelerate \
    -framework Security \
    -framework ScreenCaptureKit \
    -sdk "$SDK" \
    -O \
    -suppress-warnings

chmod +x "$APP_DEST/Contents/MacOS/voice-flow"
echo "  ✓ Swift binary compiled"

# ── codesign ───────────────────────────────────────────
# Use a stable signing identity when available so macOS keeps TCC
# permissions and Keychain access across rebuilds. Ad-hoc ("-")
# signatures change every build, which resets all grants.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -z "$SIGN_ID" ]; then
    if [ "${VF_ADHOC:-}" != "1" ]; then
        echo "  ✗ No stable Developer ID signing identity found."
        echo "    An ad-hoc build would invalidate every TCC grant (mic, screen"
        echo "    recording, accessibility) and leave stale 'On' rows in System"
        echo "    Settings. Unlock the login keychain and retry, or force with:"
        echo "      VF_ADHOC=1 ./install.sh"
        exit 1
    fi
    SIGN_ID="-"
    echo "  ⚠ Ad-hoc signature forced — permissions must be re-granted after this build."
else
    echo "  Signing with: $SIGN_ID"
fi

codesign --force --sign "$SIGN_ID" --identifier "com.voiceflow.app" \
    "$APP_DEST/Contents/MacOS/voice-flow"
codesign --force --deep --sign "$SIGN_ID" "$APP_DEST"

# ── deploy watcher assets ──────────────────────────────
# Canonical sources for the workflow-watcher pieces that live outside the
# app bundle (nightly-review LaunchAgent, its ANALYZE.md protocol + tool
# grants, the /screenwatch skill) are in watcher/ — see watcher/README.md.
WATCHER_SRC="$PROJECT_DIR/watcher"
WATCHER_DATA="$HOME/.config/voice-flow/watcher"
LA_NAME="com.voiceflow.watcher-analyze"
LA_PLIST="$HOME/Library/LaunchAgents/$LA_NAME.plist"

mkdir -p "$WATCHER_DATA/.claude" "$HOME/Library/LaunchAgents" \
    "$HOME/.claude/skills/screenwatch" "$HOME/.codex/skills/screenwatch"
cp "$WATCHER_SRC/ANALYZE.md"                "$WATCHER_DATA/ANALYZE.md"
cp "$WATCHER_SRC/claude-settings.json"      "$WATCHER_DATA/.claude/settings.json"
cp "$WATCHER_SRC/screenwatch-skill/SKILL.md" "$HOME/.claude/skills/screenwatch/SKILL.md"
cp "$WATCHER_SRC/screenwatch-skill/SKILL.md" "$HOME/.codex/skills/screenwatch/SKILL.md"
sed "s|__HOME__|$HOME|g" "$WATCHER_SRC/$LA_NAME.plist" > "$LA_PLIST"
launchctl bootout "gui/$(id -u)/$LA_NAME" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LA_PLIST" \
    && echo "  ✓ Watcher assets deployed ($LA_NAME loaded)" \
    || echo "  ⚠ Watcher assets copied, but loading $LA_NAME failed — nightly review won't run"

echo ""
echo "✓ Installed to $APP_DEST"
echo ""
echo "Launch: open /Applications/Voice\\ Flow.app"
echo "Uninstall: $PROJECT_DIR/uninstall.sh"
