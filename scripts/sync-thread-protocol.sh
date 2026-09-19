#!/bin/bash
# Copy the generated contract files (one Swift file, its fixture table and one
# Kotlin file for every contract package) into swift/Generated/ and the Android
# source tree, and every contract set's fixtures into contract-fixtures/<set>/,
# from the Atika repository, pinned to the commit named in thread-protocol.lock.
#
#   scripts/sync-thread-protocol.sh --update <atika-commit>   pin a new commit, then copy
#   scripts/sync-thread-protocol.sh                           copy again from the pinned commit
#   scripts/sync-thread-protocol.sh --check                   verify every copied file against the lock's per-file hash
#
# This is a copy pinned to a commit, not a package dependency: the Atika
# repository is private and large, and VoiceFlow needs a handful of files.
# --check verifies every copied file against a per-file sha256 line in the lock
# and needs neither the Atika repository nor the network, so install.sh runs it
# before every build. The lock is written last, through a temporary file and a
# rename, so an interrupted run leaves the lock that was there before.
#
# ATIKA_REPO        the local Atika clone (default: $HOME/repos/atika)
# VF_PROJECT_DIR    this repository (default: the parent of this script)
set -euo pipefail

PROJECT_DIR="${VF_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ATIKA_REPO="${ATIKA_REPO:-$HOME/repos/atika}"
LOCK="$PROJECT_DIR/thread-protocol.lock"
SWIFT_DEST="$PROJECT_DIR/swift/Generated"
FIXTURE_DEST="$PROJECT_DIR/contract-fixtures"
KOTLIN_DEST="$PROJECT_DIR/android/app/src/main/kotlin/com/voiceflow/mobile/generated"
SOURCE="packages/thread-protocol"
SWIFT_FILES=(PlatformContracts.swift PlatformContractsFixtures.swift)
KOTLIN_FILES=(PlatformContracts.kt)
STAGE=""
trap '[ -z "$STAGE" ] || rm -rf "$STAGE"; rm -f "$LOCK.writing.$$"' EXIT

fail() { echo "sync-thread-protocol: $*" >&2; exit 1; }

lock_value() {
    [ -f "$LOCK" ] || fail "thread-protocol.lock is missing; run: scripts/sync-thread-protocol.sh --update <atika-commit>"
    local value
    value="$(sed -n "s/^$1=//p" "$LOCK" | head -n 1)"
    [ -n "$value" ] || fail "thread-protocol.lock has no $1"
    echo "$value"
}

header_value() { # <file> <label>
    sed -n "s|^// $2: ||p" "$1" | head -n 1
}

# Reads two "<sha256> <path>" listings — the lock's and the one just computed —
# and prints the first disagreement in the words --check reports, or nothing.
# One pass over both, so a tree of hundreds of copied files costs one `awk`.
first_disagreement() { # <file of wanted lines> <file of present lines>
    /usr/bin/awk '
        function hash(line) { return substr(line, 1, index(line, " ") - 1) }
        function path(line) { return substr(line, index(line, " ") + 1) }
        NR == FNR { if (length($0)) { order[++wanted] = path($0); want[path($0)] = hash($0) } ; next }
        length($0) { here = path($0); have[here] = hash($0); seen[++found] = here }
        END {
            for (i = 1; i <= wanted; i++) {
                file = order[i]
                if (!(file in have)) {
                    print "thread-protocol.lock lists " file ", which is not there"
                    exit
                }
                if (have[file] != want[file]) {
                    print file " does not match thread-protocol.lock: " have[file] ", not " want[file]
                    exit
                }
            }
            if (found != wanted) {
                for (i = 1; i <= found; i++) {
                    if (!(seen[i] in want)) {
                        print seen[i] " is on disk and not in thread-protocol.lock"
                        exit
                    }
                }
                print found " copied file(s) are on disk, " wanted " are in thread-protocol.lock"
            }
        }' "$1" "$2"
}

# Every file this script writes, as "<sha256> <path relative to PROJECT_DIR>",
# in a stable order. `shasum`, `awk` and `sort` each read their whole input, so
# no stage can take SIGPIPE under `set -o pipefail`.
copied_files() {
    local file
    for file in "${SWIFT_FILES[@]/#/$SWIFT_DEST/}" "${KOTLIN_FILES[@]/#/$KOTLIN_DEST/}"; do
        printf '%s\n' "$file"
    done
    # Names beginning with a dot are skipped. `.DS_Store` is not a copied file,
    # and .gitignore hides it from `git status`, so counting it would fail
    # `--check` — and with it every `./install.sh` — on a tree that is correct.
    [ -d "$FIXTURE_DEST" ] && find "$FIXTURE_DEST" -name '.*' -prune -o -type f -print
    return 0
}

# One `shasum` over every file, never one process per file: `--check` runs
# before every `./install.sh`, and the list grows with every contract set the
# generator adds. Measured on this Mac at 227 copied files: 7.5 s became 0.1 s.
copied_hashes() {
    local files=() file
    while IFS= read -r file; do files+=("$file"); done < <(copied_files | LC_ALL=C sort)
    [ "${#files[@]}" -gt 0 ] || return 0
    /usr/bin/shasum -a 256 "${files[@]}" |
        /usr/bin/awk -v prefix="$PROJECT_DIR/" '
            {
                hash = $1
                path = substr($0, index($0, "  ") + 2)
                if (substr(path, 1, length(prefix)) == prefix) path = substr(path, length(prefix) + 1)
                print hash, path
            }'
}

# The lock is written last and renamed into place, so a run that dies during the
# copy leaves the lock that was there before rather than one that describes
# files that are not on disk.
write_lock() { # <commit> <version> <schema>
    local temporary="$LOCK.writing.$$"
    {
        echo "# Written by scripts/sync-thread-protocol.sh. Do not edit by hand."
        echo "atika_commit=$1"
        echo "protocol_version=$2"
        echo "schema_sha256=$3"
        echo "# One sha256 line per copied file. --check recomputes every one."
        copied_hashes | sed 's|^|sha256 |'
    } > "$temporary"
    mv "$temporary" "$LOCK"
}

# The fixture table lists every contract set that has fixtures with its folder
# in the Atika repository, one per line: (contractSet: "<set>", folder: "<path>"),
# Prints "<set> <path>" per line. Neither can hold a space.
fixture_folders() { # <PlatformContractsFixtures.swift>
    sed -n 's|^ *(contractSet: "\([^"]*\)", folder: "\([^"]*\)"),$|\1 \2|p' "$1"
}

check() {
    local commit version hash failures=0 file found=0
    commit="$(lock_value atika_commit)"
    version="$(lock_value protocol_version)"
    hash="$(lock_value schema_sha256)"
    for file in "${SWIFT_FILES[@]/#/$SWIFT_DEST/}" "${KOTLIN_FILES[@]/#/$KOTLIN_DEST/}"; do
        [ -f "$file" ] || continue
        found=$((found + 1))
        if [ "$(header_value "$file" "Protocol version")" != "$version" ] ||
           [ "$(header_value "$file" "Schema sha256")" != "$hash" ] ||
           [ "$(header_value "$file" "Atika commit")" != "$commit" ]; then
            echo "sync-thread-protocol: header does not match thread-protocol.lock: ${file#"$PROJECT_DIR"/}" >&2
            failures=$((failures + 1))
        fi
    done
    [ "$found" -eq 3 ] || fail "expected PlatformContracts.swift, PlatformContractsFixtures.swift and PlatformContracts.kt; found $found generated file(s). Run: scripts/sync-thread-protocol.sh"
    local set folder
    while read -r set folder; do
        [ -d "$FIXTURE_DEST/$set" ] || fail "the fixtures of $set are missing. Run: scripts/sync-thread-protocol.sh"
    done < <(fixture_folders "$SWIFT_DEST/PlatformContractsFixtures.swift")
    [ -d "$FIXTURE_DEST/thread-protocol/rules" ] || fail "the rule fixtures are missing. Run: scripts/sync-thread-protocol.sh"
    [ -z "$(find "$SWIFT_DEST" -type f ! -name '*.swift' -print -quit)" ] ||
        fail "swift/Generated holds a file that is not Swift; it is inside the build target. Run: scripts/sync-thread-protocol.sh"
    [ "$failures" -eq 0 ] || fail "$failures generated file(s) do not match the lock. Run: scripts/sync-thread-protocol.sh"
    # Ruling 4: every copied file, not only the three headers. Both sides are
    # one "<sha256> <path>" line per file in the same order, so they are read
    # once and compared in one pass.
    local wanted present listed difference
    wanted="$(sed -n 's/^sha256 //p' "$LOCK")"
    listed="$(printf '%s\n' "$wanted" | grep -c . || true)"
    [ "$listed" -gt 0 ] ||
        fail "thread-protocol.lock carries no file hashes. Run: scripts/sync-thread-protocol.sh"
    present="$(copied_hashes)"
    difference="$(first_disagreement <(printf '%s\n' "$wanted") <(printf '%s\n' "$present"))"
    [ -z "$difference" ] || fail "$difference. Run: scripts/sync-thread-protocol.sh"
    echo "thread protocol $version, schema ${hash:0:12}, Atika ${commit:0:12}: $found generated files and $listed copied files match the lock"
}

copy_with_commit() { # <source file> <destination file> <commit>
    # The Atika commit goes beneath the schema hash: a committed file cannot name the commit that contains it.
    awk -v line="// Atika commit: $3" '{ print } /^\/\/ Schema sha256: / && !done { print line; done = 1 }' "$1" > "$2"
}

sync() { # <commit> <version> <schema>
    local commit="$1" version="$2" schema="$3" swift_header file set folder
    git -C "$ATIKA_REPO" cat-file -e "$commit^{commit}" 2>/dev/null ||
        fail "commit $commit is not in $ATIKA_REPO; fetch it or set ATIKA_REPO"
    STAGE="$(mktemp -d /tmp/vf-thread-protocol.XXXXXX)"
    git -C "$ATIKA_REPO" archive "$commit" "$SOURCE/generated" | tar -x -C "$STAGE"

    swift_header="$STAGE/$SOURCE/generated/swift/PlatformContracts.swift"
    [ "$(header_value "$swift_header" "Protocol version")" = "$version" ] ||
        fail "the lock's protocol_version does not match commit $commit; run --update $commit"
    [ "$(header_value "$swift_header" "Schema sha256")" = "$schema" ] ||
        fail "the lock's schema_sha256 does not match commit $commit; run --update $commit"

    # swift/Generated/ and contract-fixtures/ hold nothing but what this script
    # writes, so everything in both is replaced: the fixtures of a contract set
    # that is gone, and a file from before the combined output, go too.
    rm -rf "$SWIFT_DEST" "$FIXTURE_DEST"
    rm -f "$KOTLIN_DEST"/ThreadProtocol*.kt "${KOTLIN_FILES[@]/#/$KOTLIN_DEST/}"
    mkdir -p "$SWIFT_DEST" "$FIXTURE_DEST" "$KOTLIN_DEST"
    for file in "${SWIFT_FILES[@]}"; do
        copy_with_commit "$STAGE/$SOURCE/generated/swift/$file" "$SWIFT_DEST/$file" "$commit"
    done
    for file in "${KOTLIN_FILES[@]}"; do
        copy_with_commit "$STAGE/$SOURCE/generated/kotlin/$file" "$KOTLIN_DEST/$file" "$commit"
    done
    while read -r set folder; do
        git -C "$ATIKA_REPO" archive "$commit" "$folder" | tar -x -C "$STAGE"
        mkdir -p "$FIXTURE_DEST/$set"
        cp -R "$STAGE/$folder/." "$FIXTURE_DEST/$set/"
    done < <(fixture_folders "$SWIFT_DEST/PlatformContractsFixtures.swift")
    # The copy is finished; only now is the lock replaced.
    write_lock "$commit" "$version" "$schema"
    check
}

# The command whose status decides "has this commit the file?" is a single
# `git show`, never a pipeline: under `set -o pipefail`, a `| head -n 8` would
# close the pipe after eight lines, git would die of SIGPIPE with status 141,
# and --update would refuse a commit that plainly has the file. `sed -n 1p`
# reads its whole input, so no stage can take SIGPIPE.
update() { # <commit-ish>
    local commit header version schema
    commit="$(git -C "$ATIKA_REPO" rev-parse --verify "$1^{commit}" 2>/dev/null)" ||
        fail "$1 is not a commit in $ATIKA_REPO"
    header="$(git -C "$ATIKA_REPO" show "$commit:$SOURCE/generated/swift/PlatformContracts.swift" 2>/dev/null)" ||
        fail "commit $commit has no $SOURCE/generated/swift/PlatformContracts.swift"
    version="$(printf '%s\n' "$header" | sed -n 's|^// Protocol version: ||p' | sed -n 1p)"
    schema="$(printf '%s\n' "$header" | sed -n 's|^// Schema sha256: ||p' | sed -n 1p)"
    [ -n "$version" ] && [ -n "$schema" ] ||
        fail "commit $commit's PlatformContracts.swift carries no protocol version or schema hash"
    sync "$commit" "$version" "$schema"
}

case "${1:-}" in
    --check) check ;;
    --update) [ -n "${2:-}" ] || fail "--update needs an Atika commit"; update "$2" ;;
    "") sync "$(lock_value atika_commit)" "$(lock_value protocol_version)" "$(lock_value schema_sha256)" ;;
    *) fail "unknown argument: $1" ;;
esac
