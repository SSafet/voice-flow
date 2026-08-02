#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$PROJECT_DIR/runtime/opencode/versions.json"
DESTINATION="${1:?usage: prepare-opencode-runtime.sh DESTINATION}"

case "$(uname -m)" in
    arm64) ARCH="arm64" ;;
    x86_64) ARCH="x86_64" ;;
    *) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 2 ;;
esac

read_manifest() {
    /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
}

VERSION="$(read_manifest version)"
URL="$(read_manifest "assets.$ARCH.url")"
ARCHIVE_SHA="$(read_manifest "assets.$ARCH.archiveSHA256")"
BINARY_SHA="$(read_manifest "assets.$ARCH.binarySHA256")"
FALLBACK="$(read_manifest "developerFallbacks.$ARCH.path")"
SOURCE_OVERRIDE="${VOICE_FLOW_OPENCODE_BINARY:-}"

sha256() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

mkdir -p "$DESTINATION"
TARGET="$DESTINATION/opencode"

SOURCE=""
if [ -n "$SOURCE_OVERRIDE" ] && [ -x "$SOURCE_OVERRIDE" ]; then
    SOURCE="$SOURCE_OVERRIDE"
elif [ -x "$FALLBACK" ]; then
    SOURCE="$FALLBACK"
fi

if [ -n "$SOURCE" ] && [ "$(sha256 "$SOURCE")" = "$BINARY_SHA" ]; then
    /bin/cp "$SOURCE" "$TARGET"
else
    STAGE="$(mktemp -d /tmp/voice-flow-opencode.XXXXXX)"
    trap '/bin/rm -rf "$STAGE"' EXIT
    ARCHIVE="$STAGE/opencode.zip"
    /usr/bin/curl -fL --retry 3 --proto '=https' --tlsv1.2 "$URL" -o "$ARCHIVE"
    ACTUAL_ARCHIVE_SHA="$(sha256 "$ARCHIVE")"
    if [ "$ACTUAL_ARCHIVE_SHA" != "$ARCHIVE_SHA" ]; then
        echo "OpenCode archive checksum mismatch for $ARCH" >&2
        exit 1
    fi
    /usr/bin/ditto -x -k "$ARCHIVE" "$STAGE/extracted"
    SOURCE="$STAGE/extracted/opencode"
    if [ ! -f "$SOURCE" ]; then
        echo "OpenCode archive did not contain the expected binary" >&2
        exit 1
    fi
    /bin/cp "$SOURCE" "$TARGET"
fi

/bin/chmod 755 "$TARGET"
ACTUAL_BINARY_SHA="$(sha256 "$TARGET")"
if [ "$ACTUAL_BINARY_SHA" != "$BINARY_SHA" ]; then
    echo "OpenCode binary checksum mismatch for $ARCH" >&2
    exit 1
fi
if [ "$("$TARGET" --version)" != "$VERSION" ]; then
    echo "OpenCode binary version does not match pinned $VERSION" >&2
    exit 1
fi
/bin/cp "$MANIFEST" "$DESTINATION/versions.json"
/usr/bin/printf '{"version":"%s","architecture":"%s","sourceBinarySHA256":"%s","installedBinarySHA256":"%s"}\n' \
    "$VERSION" "$ARCH" "$BINARY_SHA" "$ACTUAL_BINARY_SHA" \
    > "$DESTINATION/installed.json"
echo "Prepared OpenCode $VERSION ($ARCH, $ACTUAL_BINARY_SHA)"
