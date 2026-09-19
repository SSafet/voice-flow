#!/bin/bash
# The thread store, linked against the GRDB the package built, because this
# suite needs GRDB and scripts/test-agent-harness.sh's compile_and_run calls
# swiftc directly.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"

# Measured on this Mac on 2026-09-19 with Swift 6.4: `--show-bin-path` answers
# `.build/out/Products/Debug`, which holds `GRDB.swiftmodule` and the object
# archive `GRDB.o`. There is no `Modules` folder and no `libGRDB.a`, so `-I
# "$BIN/Modules" -L "$BIN" -lGRDB` finds nothing. GRDB also imports its own
# system-library target `GRDBSQLite`, whose module map is in the checkout and
# is not copied into the products folder; without it the compile stops at
# `error: missing required module 'GRDBSQLite'`. Both are found by searching
# the build folder, so a later toolchain that moves them is reported here
# rather than silently skipping the suite.
GRDB_OBJECT="$(/usr/bin/find "$BIN" -maxdepth 1 -name 'GRDB.o' -print -quit)"
GRDB_MODULEMAP="$(/usr/bin/find "$REPO_ROOT/.build" -path '*GRDBSQLite*' -name 'module.modulemap' -print -quit)"
if [ -z "$GRDB_OBJECT" ] || [ -z "$GRDB_MODULEMAP" ]; then
    echo "not ok - GRDB's object file or GRDBSQLite's module map is not where this runner looks." >&2
    echo "  products: $BIN" >&2
    /bin/ls "$BIN" >&2
    exit 1
fi

swiftc -o /tmp/vf-thread-store \
    -I "$BIN" -Xcc -fmodule-map-file="$GRDB_MODULEMAP" "$GRDB_OBJECT" \
    swift/VoiceFlowPaths.swift swift/Store/Migrations.swift swift/Store/Database.swift \
    tests/thread_store/main.swift \
    -suppress-warnings
/tmp/vf-thread-store
