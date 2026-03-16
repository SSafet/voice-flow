#!/bin/bash
# Install Voice Flow to /Applications
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Voice Flow"
APP_DEST="/Applications/$APP_NAME.app"
VENV="$PROJECT_DIR/.venv"
VENV_PYTHON="$VENV/bin/python"

echo "Installing $APP_NAME..."

# Preflight
if [ ! -d "$VENV" ]; then
    echo "Error: No .venv found. Run 'cd $PROJECT_DIR && uv sync' first."
    exit 1
fi

# Discover Python paths
PYTHON_HOME="$("$VENV_PYTHON" -c "import sys; print(sys.base_prefix)")"
PYTHON_VER="$("$VENV_PYTHON" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")"

# Find the ACTUAL binary that runs (not the stub that re-execs through Python.app)
# ps shows this as: .../Python.app/Contents/MacOS/Python
GUI_PYTHON="$PYTHON_HOME/Resources/Python.app/Contents/MacOS/Python"
if [ ! -f "$GUI_PYTHON" ]; then
    # Fallback: use the regular binary
    GUI_PYTHON="$(realpath "$VENV_PYTHON")"
fi

echo "  Python GUI binary: $GUI_PYTHON"
echo "  Python home:       $PYTHON_HOME"
echo "  Python version:    $PYTHON_VER"

# Remove old installation
rm -rf "$APP_DEST"

# Copy the .app template
cp -R "$PROJECT_DIR/$APP_NAME.app" "$APP_DEST"

# Copy the REAL Python GUI binary into the .app bundle (not a symlink!)
# macOS identifies processes by the binary's location — inside Voice Flow.app,
# permissions will be attributed to "Voice Flow" instead of "python3.11"
cp "$GUI_PYTHON" "$APP_DEST/Contents/MacOS/VoiceFlow-python"

# Ad-hoc codesign (required on Apple Silicon for copied binaries)
codesign --force --sign - "$APP_DEST/Contents/MacOS/VoiceFlow-python"

# Bake paths into the launcher
sed -i '' "s|__PROJECT_DIR__|$PROJECT_DIR|g"   "$APP_DEST/Contents/MacOS/voice-flow"
sed -i '' "s|__PYTHON_HOME__|$PYTHON_HOME|g"   "$APP_DEST/Contents/MacOS/voice-flow"
sed -i '' "s|__PYTHON_VER__|$PYTHON_VER|g"     "$APP_DEST/Contents/MacOS/voice-flow"
chmod +x "$APP_DEST/Contents/MacOS/voice-flow"

echo ""
echo "✓ Installed to $APP_DEST"
echo ""
echo "Launch: open /Applications/Voice\\ Flow.app"
echo "   or:  Spotlight → Voice Flow"
