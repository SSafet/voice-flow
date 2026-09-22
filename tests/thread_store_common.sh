#!/bin/bash
# Builds and runs one work-package-V1 suite.
#
# These suites need GRDB, so they cannot go through the harness's
# `compile_and_run`, which calls `swiftc` directly with no package. They are
# built the way the app is built (work package K8), exactly as K8's own
# `tests/thread_store/test.sh` does.
#
# Sourced by tests/thread_store_*/test.sh.

build_and_run_store_suite() (
    local suite="$1"
    local repo_root="$2"

    cd "$repo_root"

    if [ ! -f "$repo_root/Package.swift" ]; then
        echo "SKIP-BLOCKED: $suite needs the Swift Package Manager build of work package K8." >&2
        echo "Rebase this worktree on the platform branch once K8 has landed." >&2
        return 1
    fi

    # Never the owner's data, never the owner's port.
    local run_root
    run_root="$(mktemp -d "${TMPDIR:-/tmp}/vf-$suite-XXXXXX")" || return $?
    trap 'rm -rf "$run_root"' EXIT
    export VOICE_FLOW_CONFIG_ROOT="$run_root/config"
    export VOICE_FLOW_QA_PORT=18793
    mkdir -p "$VOICE_FLOW_CONFIG_ROOT" || return $?

    # These suites link GRDB directly; the app's release/QA compile is a
    # separate harness gate and need not run four times here.
    swift build -c debug --target GRDB -Xswiftc -suppress-warnings >/dev/null || return $?
    local bin
    bin="$(swift build -c debug --show-bin-path)" || return $?
    local object modulemap
    object="$bin/GRDB.o"
    modulemap="$(/usr/bin/find "$repo_root/.build" -path '*GRDBSQLite*' -name 'module.modulemap' -print -quit)"
    if [ ! -f "$object" ] || [ -z "$modulemap" ]; then
        echo "not ok - GRDB.o or GRDBSQLite's module map is missing (products: $bin)" >&2
        return 1
    fi

    local binary="$run_root/$suite"
    swiftc -o "$binary" -I "$bin" -Xcc "-fmodule-map-file=$modulemap" "$object" -suppress-warnings \
        "$repo_root"/swift/VoiceFlowPaths.swift \
        "$repo_root"/swift/Store/Migrations.swift \
        "$repo_root"/swift/Store/Database.swift \
        "$repo_root"/swift/Contract/CleanText.swift \
        "$repo_root"/swift/Contract/FirstLineTitle.swift \
        "$repo_root"/swift/Contract/ThreadBranchName.swift \
        "$repo_root"/swift/Generated/PlatformContracts.swift \
        "$repo_root"/swift/Threads/Store/*.swift \
        "$repo_root"/swift/Threads/Projects/*.swift \
        "$repo_root"/tests/thread_store_support/Fixtures.swift \
        "$repo_root/tests/$suite/main.swift" || return $?

    local status=0
    if "$binary"; then
        status=0
    else
        status=$?
    fi
    return "$status"
)
