#!/bin/bash
# The running-system fact of work package S6 (07 section 8 item 12), run later
# by the design lead against a copy of the real configuration folder:
#
#   tests/data_sources_removed/running-system.sh <config-root> <baseline-files> <baseline-bytes>
#
# It observes that the live snapshot folder is gone, that the legacy folder
# holds the same number of files and bytes, and that every dictation that
# occurs in the moved builtin-dictations copies is in the dictation archive.
# Set S6_WAIT_SECONDS to re-count the legacy folder after a pause and require
# the count not to change (the "an hour apart" check).
set -euo pipefail

[ "$#" -eq 3 ] || { echo "usage: $0 <config-root> <baseline-files> <baseline-bytes>" >&2; exit 2; }
ROOT="$1"
BASELINE_FILES="$2"
BASELINE_BYTES="$3"
[ -d "$ROOT" ] || { echo "not ok - $ROOT is not a directory" >&2; exit 1; }

count() { find "$1" -type f -print | wc -l | tr -d ' '; }
bytes() { find "$1" -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }'; }

[ ! -e "$ROOT/source-snapshots" ] || { echo "not ok - $ROOT/source-snapshots still exists" >&2; exit 1; }
echo "ok 1 - source-snapshots no longer exists"

LEGACY="$(find "$ROOT/legacy" -maxdepth 1 -type d -name 'data-sources-*' 2>/dev/null | sort | tail -n 1)"
[ -n "$LEGACY" ] || { echo "not ok - no legacy/data-sources-<date> folder under $ROOT/legacy" >&2; exit 1; }
echo "ok 2 - the legacy folder is $LEGACY"

FILES="$(count "$LEGACY")"
BYTES="$(bytes "$LEGACY")"
[ "$FILES" = "$BASELINE_FILES" ] || { echo "not ok - $FILES files vs baseline $BASELINE_FILES" >&2; exit 1; }
[ "$BYTES" = "$BASELINE_BYTES" ] || { echo "not ok - $BYTES bytes vs baseline $BASELINE_BYTES" >&2; exit 1; }
echo "ok 3 - $FILES files and $BYTES bytes match the baseline"

ARCHIVE="$ROOT/dictations"
[ -d "$ARCHIVE" ] || { echo "not ok - the dictation archive $ARCHIVE does not exist" >&2; exit 1; }
MISSING=0
while IFS= read -r copy; do
    text="$(cat "$copy")"
    [ -n "$text" ] || continue
    grep -Fq "\"$text\"" "$ARCHIVE"/*.jsonl 2>/dev/null || { echo "missing from archive: $copy" >&2; MISSING=$((MISSING + 1)); }
done < <(find "$LEGACY" -path '*builtin-dictations*' -type f -name 'item-*.txt')
[ "$MISSING" -eq 0 ] || { echo "not ok - $MISSING dictation copies are not in the archive" >&2; exit 1; }
echo "ok 4 - every builtin-dictations copy is in the dictation archive"

if [ -n "${S6_WAIT_SECONDS:-}" ]; then
    sleep "$S6_WAIT_SECONDS"
    LATER_FILES="$(count "$LEGACY")"
    [ "$LATER_FILES" = "$FILES" ] || { echo "not ok - the count changed to $LATER_FILES after the pause" >&2; exit 1; }
    echo "ok 5 - the count is unchanged after $S6_WAIT_SECONDS seconds"
fi

echo "S6 running-system observation passed"
