#!/bin/bash
# Builds and runs one V8 unit suite (outside_sessions_threads,
# outside_sessions_turns).
#
# These suites compile the package's own sources, the generated contract types
# and K8's first-line-title rule, plus the package's own seams. They never
# compile `swift/Threads/OutsideSessions/Adapters/**`, which names V1, V5 and
# V6 — the pattern V5's suites use. Nothing here needs GRDB, so the suite is a
# plain `swiftc` compile. The integration suite (`outside_sessions_store`) goes
# through Swift Package Manager because it compiles V1's store.
#
# Sourced by tests/outside_sessions_*/test.sh.

outside_sessions_sources() {
    printf '%s\n' \
        "swift/Generated/PlatformContracts.swift" \
        "swift/Contract/FirstLineTitle.swift" \
        "swift/MCP.swift" \
        "swift/Threads/OutsideSessions/OutsideSessionTypes.swift" \
        "swift/Threads/OutsideSessions/OutsideSessionStore.swift" \
        "swift/Threads/OutsideSessions/OutsideSessionBridge.swift" \
        "tests/outside_sessions/support.swift"
}

build_and_run_unit_suite() {
    local suite="$1"
    local repo_root="$2"
    cd "$repo_root" || exit 1

    local file
    for file in $(outside_sessions_sources); do
        [ -f "$repo_root/$file" ] ||
            { echo "BLOCKED: $suite needs $file, which is not here yet." >&2
              echo "The package's own files arrive in tasks 1 to 3; K8's Contract/ arrives with K8." >&2
              exit 1; }
    done
    [ -f "$repo_root/tests/$suite/main.swift" ] ||
        { echo "BLOCKED: tests/$suite/main.swift is missing." >&2; exit 1; }

    local build_dir binary
    build_dir="$(mktemp -d "${TMPDIR:-/tmp}/vf-$suite-XXXXXX")"
    binary="$build_dir/$suite"
    # shellcheck disable=SC2046
    xcrun swiftc $(outside_sessions_sources) "$repo_root/tests/$suite/main.swift" \
        -o "$binary" -suppress-warnings || exit 1

    local status=0
    "$binary" || status=$?
    rm -rf "$build_dir"
    return "$status"
}
