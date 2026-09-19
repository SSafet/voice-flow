#!/bin/bash
# Work package L1M: the device identity on the Mac (05 C18, C19; decision 23).
#
# The suites compile the real sources. The key store's suite needs nothing but
# the macOS SDK; the identity and takeover suites need K8's one threads.sqlite
# and GRDB, so they are built the way the app is built.
#
# Run with the task number in the environment (or as the first argument) and
# only the suites due by then run: OC_TASK_N=1 key store; 2 identity; 3 takeover.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
THROUGH="${1:-${OC_TASK_N:-99}}"
XCODE_SDK="$(xcrun --show-sdk-path)"
BUILD="$(mktemp -d /tmp/vf-device-identity.XXXXXX)"
trap 'rm -rf "$BUILD"' EXIT

fail() { echo "not ok - $1" >&2; exit 1; }

run_key_store() {
    [ -f swift/Device/KeyStore.swift ] ||
        fail "swift/Device/KeyStore.swift is not implemented yet (task 1)"
    echo "RUN: device key store"
    swiftc -o "$BUILD/key_store_test" \
        swift/Device/KeyStore.swift \
        tests/device_identity/Harness.swift tests/device_identity/TestKeys.swift \
        tests/device_identity/key_store_test.swift \
        -framework Security -sdk "$XCODE_SDK" -suppress-warnings
    "$BUILD/key_store_test"
}

ensure_app_build() {
    [ -f Package.swift ] ||
        fail "K8's Package.swift is not in this worktree; rebase on platform after K8 lands"
    [ -f swift/VoiceFlowPaths.swift ] && [ -f swift/Store/Database.swift ] && [ -f swift/Store/Migrations.swift ] ||
        fail "K8's one threads.sqlite sources are not in this worktree; rebase on platform after K8 lands"
    swift build --package-path "$REPO_ROOT" -c debug -Xswiftc -suppress-warnings
    BIN="$(swift build --package-path "$REPO_ROOT" -c debug --show-bin-path)"
}

# GRDB's module may sit beside the libraries rather than under Modules on a
# different toolchain; fall back to the bin path itself, as K8's thread-store
# runner says to do.
compile_identity_suite() {
    local main="$1" output="$2" log="$3" include
    for include in "$BIN/Modules" "$BIN"; do
        if swiftc -o "$output" -I "$include" -L "$BIN" \
            swift/VoiceFlowPaths.swift swift/Store/Migrations.swift swift/Store/Database.swift \
            swift/Device/KeyStore.swift swift/Device/DeviceIdentity.swift \
            tests/device_identity/Harness.swift tests/device_identity/TestKeys.swift \
            tests/device_identity/TestDatabase.swift tests/device_identity/FakeGateway.swift \
            "$main" \
            -lGRDB -framework Security -sdk "$XCODE_SDK" -suppress-warnings 2>"$log"; then
            return 0
        fi
    done
    cat "$log" >&2
    return 1
}

run_identity() {
    [ -f swift/Device/DeviceIdentity.swift ] ||
        fail "swift/Device/DeviceIdentity.swift is not implemented yet (task 2)"
    ensure_app_build
    compile_identity_suite tests/device_identity/identity_test.swift "$BUILD/identity_test" "$BUILD/identity-compile.log"
    echo "RUN: device identity"
    "$BUILD/identity_test"
}

run_takeover() {
    [ -f swift/Device/DeviceIdentity.swift ] ||
        fail "swift/Device/DeviceIdentity.swift is not implemented yet (task 3)"
    ensure_app_build
    compile_identity_suite tests/device_identity/takeover_test.swift "$BUILD/takeover_test" "$BUILD/takeover-compile.log"
    echo "RUN: home takeover"
    "$BUILD/takeover_test"
}

if [ "$THROUGH" -ge 1 ]; then run_key_store; fi
if [ "$THROUGH" -ge 2 ]; then run_identity; fi
if [ "$THROUGH" -ge 3 ]; then run_takeover; fi
echo "device identity: all suites due through task $THROUGH passed"
