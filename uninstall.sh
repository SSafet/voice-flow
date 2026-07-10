#!/bin/bash
set -e

APP_NAME="Voice Flow"
APP_DEST="/Applications/$APP_NAME.app"
BUNDLE_ID="com.voiceflow.app"
CONFIG_DIR="$HOME/.config/voice-flow"
CACHE_DIR="$HOME/Library/Caches/com.voiceflow.app"
REMOVE_USER_DATA=false

if [ "${1:-}" = "--remove-user-data" ]; then
    REMOVE_USER_DATA=true
fi

echo "Uninstalling $APP_NAME..."

pkill -x "voice-flow" 2>/dev/null || true
rm -rf "$APP_DEST"

# Watcher pieces deployed by install.sh (sources: watcher/ in the repo).
# Data (day folders, ledger.md, reviews/) is kept unless --remove-user-data.
LA_NAME="com.voiceflow.watcher-analyze"
launchctl bootout "gui/$(id -u)/$LA_NAME" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LA_NAME.plist"
rm -rf "$HOME/.claude/skills/screenwatch"
rm -f "$CONFIG_DIR/watcher/ANALYZE.md" "$CONFIG_DIR/watcher/.claude/settings.json"
rmdir "$CONFIG_DIR/watcher/.claude" 2>/dev/null || true

if [ "$REMOVE_USER_DATA" = true ]; then
    rm -rf "$CONFIG_DIR"
    rm -rf "$CACHE_DIR"
    security delete-generic-password -s "$BUNDLE_ID" -a "openai_api_key" >/dev/null 2>&1 || true
    tccutil reset All "$BUNDLE_ID" || true
fi

echo ""
if [ "$REMOVE_USER_DATA" = true ]; then
    echo "✓ Removed app bundle, config, cached TTS audio, saved API key, and reset permissions for $BUNDLE_ID"
else
    echo "✓ Removed app bundle, nightly-review LaunchAgent, and /screenwatch skill"
    echo "  Kept config, watcher data, cached TTS audio, saved API key, and permissions."
    echo "  Run '$0 --remove-user-data' for a full data reset."
fi
