#!/bin/bash
set -e

APP_NAME="Voice Flow"
APP_DEST="/Applications/$APP_NAME.app"
BUNDLE_ID="com.voiceflow.app"
CONFIG_DIR="$HOME/.config/voice-flow"
CACHE_DIR="$HOME/Library/Caches/com.voiceflow.app"

echo "Uninstalling $APP_NAME..."

pkill -x "voice-flow" 2>/dev/null || true
rm -rf "$APP_DEST"
rm -rf "$CONFIG_DIR"
rm -rf "$CACHE_DIR"

security delete-generic-password -s "$BUNDLE_ID" -a "openai_api_key" >/dev/null 2>&1 || true
tccutil reset All "$BUNDLE_ID" || true

echo ""
echo "✓ Removed app bundle, config, cached TTS audio, saved API key, and reset permissions for $BUNDLE_ID"
