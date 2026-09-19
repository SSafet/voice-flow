#!/bin/bash
# The link table, the reverse path lookup and the rebuild, linked against the
# GRDB the package built, because CapturedIndex is a GRDB store and
# scripts/test-agent-harness.sh's compile_and_run calls swiftc directly.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

swift build -c debug --target GRDB -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"

GRDB_OBJECT="$(/usr/bin/find "$BIN" -maxdepth 1 -name 'GRDB.o' -print -quit)"
GRDB_MODULEMAP="$(/usr/bin/find "$REPO_ROOT/.build" -path '*GRDBSQLite*' -name 'module.modulemap' -print -quit)"
if [ -z "$GRDB_OBJECT" ] || [ -z "$GRDB_MODULEMAP" ]; then
    echo "not ok - GRDB's object file or GRDBSQLite's module map is not where this runner looks." >&2
    echo "  products: $BIN" >&2
    /bin/ls "$BIN" >&2
    exit 1
fi

OUTPUT="$(mktemp -d /tmp/vf-attachment-links.XXXXXX)/run"
trap 'rm -rf "$(dirname "$OUTPUT")"' EXIT
swiftc -o "$OUTPUT" \
    -I "$BIN" -Xcc -fmodule-map-file="$GRDB_MODULEMAP" "$GRDB_OBJECT" \
    swift/Generated/PlatformContracts.swift \
    swift/VoiceFlowPaths.swift \
    swift/Captured/Store/CapturedValues.swift \
    swift/Captured/Store/CapturedItemID.swift \
    swift/Captured/Store/CapturedSchema.swift \
    swift/Captured/Store/CapturedDatabase.swift \
    swift/Captured/Store/CapturedIndex.swift \
    swift/Captured/Attachments/CapturedLinks.swift \
    tests/attachment_links/main.swift \
    -suppress-warnings
"$OUTPUT"
