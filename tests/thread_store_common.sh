#!/bin/bash
# Builds and runs one work-package-V1 suite.
#
# These suites need GRDB, so they cannot go through the harness's
# `compile_and_run`, which calls `swiftc` directly with no package. They are
# built the way the app is built (work package K8), exactly as K8's own
# `tests/thread_store/test.sh` does.
#
# Sourced by tests/thread_store_*/test.sh.

build_and_run_store_suite() {
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
    run_root="$(mktemp -d "${TMPDIR:-/tmp}/vf-$suite-XXXXXX")"
    export VOICE_FLOW_CONFIG_ROOT="$run_root/config"
    export VOICE_FLOW_QA_PORT=18793
    mkdir -p "$VOICE_FLOW_CONFIG_ROOT"

    swift build -c debug -Xswiftc -suppress-warnings >/dev/null
    local bin
    bin="$(swift build -c debug --show-bin-path)"

    local binary="$run_root/$suite"
    swiftc -o "$binary" -I "$bin/Modules" -L "$bin" -lGRDB -suppress-warnings \
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
        "$repo_root/tests/$suite/main.swift"

    local status=0
    if ! "$binary"; then
        status=$?
    fi
    rm -rf "$run_root"
    return "$status"
}
