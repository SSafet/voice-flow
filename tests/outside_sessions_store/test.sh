#!/bin/bash
# Work package V8 — outside_sessions_store: the outside-session adapter over
# V1's ThreadStore, proved against the one threads.sqlite. It needs GRDB, so it
# is built the way the app is built (work package K8), exactly as V1's own
# suites are. It also needs V1 to have landed, because the adapter names
# ThreadStore, ProjectRegistry and their types.
set -euo pipefail

suite="outside_sessions_store"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

if [ ! -f "$repo_root/Package.swift" ]; then
    echo "BLOCKED: $suite needs the Swift Package Manager build of work package K8." >&2
    echo "Rebase this worktree on the platform branch once K8 has landed." >&2
    exit 1
fi
if [ ! -f "$repo_root/swift/Threads/Store/ThreadStore.swift" ] \
   || [ ! -f "$repo_root/swift/Threads/Projects/ProjectRegistry.swift" ]; then
    echo "BLOCKED: $suite needs V1's store and project registry." >&2
    echo "Rebase this worktree once work package V1 has landed." >&2
    exit 1
fi
if [ ! -f "$repo_root/swift/Threads/OutsideSessions/Adapters/StoreOutsideSessionStore.swift" ]; then
    echo "BLOCKED: $suite needs V8's store adapter (task 4)." >&2
    exit 1
fi

run_root="$(mktemp -d "${TMPDIR:-/tmp}/vf-$suite-XXXXXX")"
export VOICE_FLOW_CONFIG_ROOT="$run_root/config"
export VOICE_FLOW_QA_PORT=18793
mkdir -p "$VOICE_FLOW_CONFIG_ROOT"

swift build -c debug -Xswiftc -suppress-warnings >/dev/null
bin="$(swift build -c debug --show-bin-path)"

binary="$run_root/$suite"
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
    "$repo_root"/swift/MCP.swift \
    "$repo_root"/swift/Threads/OutsideSessions/OutsideSessionTypes.swift \
    "$repo_root"/swift/Threads/OutsideSessions/OutsideSessionStore.swift \
    "$repo_root"/swift/Threads/OutsideSessions/OutsideSessionBridge.swift \
    "$repo_root"/swift/Threads/OutsideSessions/Adapters/StoreOutsideSessionStore.swift \
    "$repo_root"/tests/outside_sessions/support.swift \
    "$repo_root/tests/$suite/main.swift" || { rm -rf "$run_root"; exit 1; }

status=0
"$binary" || status=$?
rm -rf "$run_root"
exit "$status"
