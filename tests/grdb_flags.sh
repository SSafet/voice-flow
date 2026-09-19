#!/bin/bash
# Source this after `swift build -c debug` with BIN set to `swift build --show-bin-path`.
# It sets the array GRDB_LINK to what swiftc needs to compile and link a suite against the
# GRDB the package built.
#
# Two product layouts exist on this toolchain. Under `.build/out/Products/Debug` there is no
# Modules folder and no libGRDB.a: GRDB is one object file, and its system-library target
# GRDBSQLite needs its module map named (K8 measured this; tests/thread_store/test.sh explains
# it). Under `.build/<triple>/debug` there is a Modules folder and a library to link.
GRDB_LINK=()
_grdb_object="$(/usr/bin/find "$BIN" -maxdepth 1 -name 'GRDB.o' -print -quit)"
_grdb_modulemap="$(/usr/bin/find "$(pwd)/.build" -path '*GRDBSQLite*' -name 'module.modulemap' -print -quit)"
if [ -n "$_grdb_object" ] && [ -n "$_grdb_modulemap" ]; then
    GRDB_LINK=(-I "$BIN" -Xcc "-fmodule-map-file=$_grdb_modulemap" "$_grdb_object")
elif [ -d "$BIN/Modules" ]; then
    GRDB_LINK=(-I "$BIN/Modules" -L "$BIN" -lGRDB)
else
    echo "not ok - GRDB was not found in either products layout under $BIN" >&2
    /bin/ls "$BIN" >&2
    exit 1
fi
