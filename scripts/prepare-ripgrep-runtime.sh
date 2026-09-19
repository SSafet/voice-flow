#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$PROJECT_DIR/runtime/ripgrep/versions.json"
DESTINATION="${1:?usage: prepare-ripgrep-runtime.sh DESTINATION}"

case "$(uname -m)" in
    arm64) ARCH="arm64" ;;
    x86_64) ARCH="x86_64" ;;
    *) echo "Unsupported macOS architecture: $(uname -m)" >&2; exit 2 ;;
esac

read_manifest() { /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"; }
sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }

VERSION="$(read_manifest version)"
URL="$(read_manifest "assets.$ARCH.url")"
ARCHIVE_SHA="$(read_manifest "assets.$ARCH.archiveSHA256")"
BINARY_SHA="$(read_manifest "assets.$ARCH.binarySHA256")"
SOURCE_OVERRIDE="${VOICE_FLOW_RIPGREP_BINARY:-}"

mkdir -p "$DESTINATION"
TARGET="$DESTINATION/rg"

if [ -n "$SOURCE_OVERRIDE" ]; then
    # The override is how a caller hands this script a binary without the
    # network. A wrong one ends the run: falling through to a download would
    # make the checksum check pass vacuously on a binary nobody asked for.
    if [ ! -f "$SOURCE_OVERRIDE" ]; then
        echo "VOICE_FLOW_RIPGREP_BINARY is set to $SOURCE_OVERRIDE, which is not a file" >&2
        exit 1
    fi
    ACTUAL_OVERRIDE_SHA="$(sha256 "$SOURCE_OVERRIDE")"
    if [ "$ACTUAL_OVERRIDE_SHA" != "$BINARY_SHA" ]; then
        echo "VOICE_FLOW_RIPGREP_BINARY checksum mismatch for $ARCH: $ACTUAL_OVERRIDE_SHA, not $BINARY_SHA" >&2
        exit 1
    fi
    /bin/cp "$SOURCE_OVERRIDE" "$TARGET"
elif [ -f "$TARGET" ] && [ "$(sha256 "$TARGET")" = "$BINARY_SHA" ]; then
    :   # already staged and correct
else
    STAGE="$(mktemp -d /tmp/voice-flow-ripgrep.XXXXXX)"
    trap '/bin/rm -rf "$STAGE"' EXIT
    ARCHIVE="$STAGE/ripgrep.tar.gz"
    /usr/bin/curl -fL --retry 3 --proto '=https' --tlsv1.2 "$URL" -o "$ARCHIVE"
    ACTUAL_ARCHIVE_SHA="$(sha256 "$ARCHIVE")"
    if [ "$ACTUAL_ARCHIVE_SHA" != "$ARCHIVE_SHA" ]; then
        echo "ripgrep archive checksum mismatch for $ARCH" >&2
        exit 1
    fi
    /usr/bin/tar -xzf "$ARCHIVE" -C "$STAGE"
    SOURCE="$(/usr/bin/find "$STAGE" -type f -name rg -perm -u+x -print -quit)"
    if [ -z "$SOURCE" ]; then
        echo "ripgrep archive did not contain the expected binary" >&2
        exit 1
    fi
    /bin/cp "$SOURCE" "$TARGET"
fi

/bin/chmod 755 "$TARGET"
ACTUAL_BINARY_SHA="$(sha256 "$TARGET")"
if [ "$ACTUAL_BINARY_SHA" != "$BINARY_SHA" ]; then
    echo "ripgrep binary checksum mismatch for $ARCH" >&2
    exit 1
fi
REPORTED="$("$TARGET" --version | /usr/bin/sed -n 1p)"
case "$REPORTED" in
    "ripgrep $VERSION"*) ;;
    *)
        echo "ripgrep binary reports '$REPORTED', not the pinned $VERSION" >&2
        exit 1
        ;;
esac
/bin/cp "$MANIFEST" "$DESTINATION/versions.json"
echo "Prepared ripgrep $VERSION ($ARCH, $ACTUAL_BINARY_SHA)"
