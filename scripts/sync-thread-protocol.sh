#!/bin/bash
# Copy the generated contract files (one Swift file, its fixture table and one
# Kotlin file for every contract package) and every contract set's fixtures
# from the Atika repository, pinned to the commit named in thread-protocol.lock.
#
#   scripts/sync-thread-protocol.sh --update <atika-commit>   pin a new commit, then copy
#   scripts/sync-thread-protocol.sh                           copy again from the pinned commit
#   scripts/sync-thread-protocol.sh --check                   verify the copied files against the lock
#
# This is a copy pinned to a commit, not a package dependency: the Atika
# repository is private and large, and VoiceFlow needs a handful of files.
# --check needs neither the Atika repository nor the network, so install.sh
# runs it before every build.
#
# ATIKA_REPO        the local Atika clone (default: $HOME/repos/atika)
# VF_PROJECT_DIR    this repository (default: the parent of this script)
set -euo pipefail

PROJECT_DIR="${VF_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ATIKA_REPO="${ATIKA_REPO:-$HOME/repos/atika}"
LOCK="$PROJECT_DIR/thread-protocol.lock"
SWIFT_DEST="$PROJECT_DIR/swift/Generated"
KOTLIN_DEST="$PROJECT_DIR/android/app/src/main/kotlin/com/voiceflow/mobile/generated"
SOURCE="packages/thread-protocol"
SWIFT_FILES=(PlatformContracts.swift PlatformContractsFixtures.swift)
KOTLIN_FILES=(PlatformContracts.kt)
STAGE=""
trap '[ -z "$STAGE" ] || rm -rf "$STAGE"' EXIT

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
        [ -d "$SWIFT_DEST/$set-fixtures" ] || fail "the fixtures of $set are missing. Run: scripts/sync-thread-protocol.sh"
    done < <(fixture_folders "$SWIFT_DEST/PlatformContractsFixtures.swift")
    [ -d "$SWIFT_DEST/thread-protocol-fixtures/rules" ] || fail "the rule fixtures are missing. Run: scripts/sync-thread-protocol.sh"
    [ "$failures" -eq 0 ] || fail "$failures generated file(s) do not match the lock. Run: scripts/sync-thread-protocol.sh"
    echo "thread protocol $version, schema ${hash:0:12}, Atika ${commit:0:12}: $found generated files match the lock"
}

copy_with_commit() { # <source file> <destination file> <commit>
    # The Atika commit goes beneath the schema hash: a committed file cannot name the commit that contains it.
    awk -v line="// Atika commit: $3" '{ print } /^\/\/ Schema sha256: / && !done { print line; done = 1 }' "$1" > "$2"
}

sync() {
    local commit swift_header file set folder
    commit="$(lock_value atika_commit)"
    git -C "$ATIKA_REPO" cat-file -e "$commit^{commit}" 2>/dev/null ||
        fail "commit $commit is not in $ATIKA_REPO; fetch it or set ATIKA_REPO"
    STAGE="$(mktemp -d /tmp/vf-thread-protocol.XXXXXX)"
    git -C "$ATIKA_REPO" archive "$commit" "$SOURCE/generated" | tar -x -C "$STAGE"

    swift_header="$STAGE/$SOURCE/generated/swift/PlatformContracts.swift"
    [ "$(header_value "$swift_header" "Protocol version")" = "$(lock_value protocol_version)" ] ||
        fail "the lock's protocol_version does not match commit $commit; run --update $commit"
    [ "$(header_value "$swift_header" "Schema sha256")" = "$(lock_value schema_sha256)" ] ||
        fail "the lock's schema_sha256 does not match commit $commit; run --update $commit"

    # swift/Generated/ holds nothing but what this script writes, so everything in it is replaced:
    # a fixtures folder of a contract set that is gone, or a file from before the combined output, goes too.
    rm -rf "$SWIFT_DEST"
    rm -f "$KOTLIN_DEST"/ThreadProtocol*.kt "${KOTLIN_FILES[@]/#/$KOTLIN_DEST/}"
    mkdir -p "$SWIFT_DEST" "$KOTLIN_DEST"
    for file in "${SWIFT_FILES[@]}"; do
        copy_with_commit "$STAGE/$SOURCE/generated/swift/$file" "$SWIFT_DEST/$file" "$commit"
    done
    for file in "${KOTLIN_FILES[@]}"; do
        copy_with_commit "$STAGE/$SOURCE/generated/kotlin/$file" "$KOTLIN_DEST/$file" "$commit"
    done
    while read -r set folder; do
        git -C "$ATIKA_REPO" archive "$commit" "$folder" | tar -x -C "$STAGE"
        mkdir -p "$SWIFT_DEST/$set-fixtures"
        cp -R "$STAGE/$folder/." "$SWIFT_DEST/$set-fixtures/"
    done < <(fixture_folders "$SWIFT_DEST/PlatformContractsFixtures.swift")
    check
}

# The command whose status decides "has this commit the file?" is a single
# `git show`, never a pipeline: under `set -o pipefail`, a `| head -n 8` would
# close the pipe after eight lines, git would die of SIGPIPE with status 141,
# and --update would refuse a commit that plainly has the file. `sed -n 1p`
# reads its whole input, so no stage can take SIGPIPE.
update() { # <commit-ish>
    local commit header
    commit="$(git -C "$ATIKA_REPO" rev-parse --verify "$1^{commit}" 2>/dev/null)" ||
        fail "$1 is not a commit in $ATIKA_REPO"
    header="$(git -C "$ATIKA_REPO" show "$commit:$SOURCE/generated/swift/PlatformContracts.swift" 2>/dev/null)" ||
        fail "commit $commit has no $SOURCE/generated/swift/PlatformContracts.swift"
    {
        echo "# Written by scripts/sync-thread-protocol.sh --update. Do not edit by hand."
        echo "atika_commit=$commit"
        echo "protocol_version=$(printf '%s\n' "$header" | sed -n 's|^// Protocol version: ||p' | sed -n 1p)"
        echo "schema_sha256=$(printf '%s\n' "$header" | sed -n 's|^// Schema sha256: ||p' | sed -n 1p)"
    } > "$LOCK"
    sync
}

case "${1:-}" in
    --check) check ;;
    --update) [ -n "${2:-}" ] || fail "--update needs an Atika commit"; update "$2" ;;
    "") sync ;;
    *) fail "unknown argument: $1" ;;
esac
