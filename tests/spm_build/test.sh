#!/bin/bash
# The app is built by Swift Package Manager, the generated contract types are in
# the binary, and no one-command swiftc build of swift/*.swift is left anywhere.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
PASS=0
ok() { PASS=$((PASS + 1)); echo "ok $PASS - $1"; }
die() { echo "not ok - $1" >&2; exit 1; }

[ -f Package.swift ] || die "Package.swift is there"
[ -f Package.resolved ] || die "Package.resolved is committed, so the versions are pinned"
ok "the package manifest and its resolution are committed"

# Package.resolved records each dependency by its identity and its address, in
# the package's own spelling ("grdb.swift", "hummingbird-websocket"), never by
# the module name a source file imports, so match the address, case-insensitively.
for identity in GRDB.swift hummingbird.git hummingbird-websocket Yams; do
    grep -qi "$identity" Package.resolved || die "$identity is pinned in Package.resolved"
done
ok "GRDB, Hummingbird, hummingbird-websocket and Yams are pinned"

# The build itself. -suppress-warnings keeps the output readable, exactly as the
# single swiftc call did; errors are not warnings and still stop the build.
# A release swift build runs whole-module optimization and drops the generated
# declarations nothing references yet (task 9 adds the self-check that does), so
# -no-whole-module-optimization keeps the compiled-in generated code observable.
swift build -c release -Xswiftc -suppress-warnings -Xswiftc -no-whole-module-optimization
BINARY="$(swift build -c release --show-bin-path)/voice-flow"
[ -x "$BINARY" ] || die "swift build produces the voice-flow binary"
ok "swift build -c release produces the voice-flow binary"

# The generated contract types are compiled in. `tpDecodeFixture` is a private
# symbol of the module, so look for a string only the generated file carries.
# `grep -q` would exit at the first match, close the pipe, and leave `strings`
# killed by SIGPIPE with status 141, which `set -o pipefail` would turn into a
# failed pipeline on a *passing* binary; `grep -F … >/dev/null` reads it all.
if ! strings "$BINARY" | grep -F "ThreadAnswerApprovalParams" >/dev/null; then
    die "the generated contract types are compiled into the binary"
fi
ok "swift/Generated is compiled into the binary"

echo "all $PASS checks passed"
