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

# The build itself, with the flags the product ships and no others. Task 3 also
# passed -no-whole-module-optimization, because nothing referenced the generated
# declarations yet and whole-module optimization dropped them; task 9's
# self-check references them, so the flag is gone. It had to go: it made this
# suite's strongest check a statement about a binary the product never builds,
# and it flipped the release configuration in the shared .build that the gate's
# own "compile release app" step uses a moment later, paying a second full
# release compile every run.
swift build -c release -Xswiftc -suppress-warnings
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

grep -q 'swift build -c release' install.sh || die "install.sh builds with Swift Package Manager"
grep -q 'swift build -c release' scripts/test-agent-harness.sh || die "the test harness builds the app with Swift Package Manager"
grep -q 'swift build -c release' scripts/install-agent-harness-qa.sh || die "the QA installer builds with Swift Package Manager"
grep -q 'swift build' CLAUDE.md || die "CLAUDE.md tells the reader how to build"
grep -q 'swift build' AGENTS.md || die "AGENTS.md tells the reader how to build"
ok "install.sh, the QA installer, the test harness and both instruction files build with Swift Package Manager"

# The build must still refuse to run without the toolchain, and the refusal must
# name the tool the build actually uses.
grep -q 'command -v swift ' install.sh || die "install.sh checks for the swift driver before building"
ok "install.sh checks for the swift driver"

# Nothing that builds or documents the app may compile swift/*.swift with one
# swiftc call any more. The search names the four files that build or document
# the app and the scripts folder: two historical design documents
# (design/ticket-22-capability-routing-plan.md:364 and
# design/assistant-session-history-plan.md:237) quote the old command as a
# record of how the app was built then, and a repository-wide search would
# never go green because of them. Nothing under .build/ is searched either.
LEFTOVER="$(grep -rn 'swiftc .*swift/\*\.swift' install.sh CLAUDE.md AGENTS.md scripts/ || true)"
[ -z "$LEFTOVER" ] || die "a one-command swiftc build of swift/*.swift is left: $LEFTOVER"
ok "no one-command swiftc build of swift/*.swift is left in install.sh, the scripts or the instruction files"

PLIST="Voice Flow.app/Contents/Info.plist"
[ "$(/usr/bin/plutil -extract LSMinimumSystemVersion raw -o - "$PLIST")" = "14.0" ] ||
    die "LSMinimumSystemVersion is 14.0, the floor hummingbird-websocket declares"
[ "$(/usr/bin/plutil -extract NSAppTransportSecurity.NSExceptionDomains.localhost.NSExceptionAllowsInsecureHTTPLoads raw -o - "$PLIST")" = "true" ] ||
    die "plain HTTP is allowed for the host localhost"
/usr/bin/plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw -o - "$PLIST" >/dev/null 2>&1 &&
    die "NSAllowsLocalNetworking must not be set"
[ "$(/usr/bin/plutil -extract NSAppTransportSecurity.NSExceptionDomains raw -o - "$PLIST" | grep -c .)" -ge 1 ] ||
    die "the exception domains dictionary is readable"
ok "the bundle admits macOS 14 and allows plain HTTP for localhost and nothing else"

# R12: the single swiftc build and the quick type-check command are gone, and
# these greps are what keeps them gone. They must be able to find something:
printf 'swiftc swift/*.swift -framework Cocoa\n' > /tmp/k8-subtraction-probe.sh
grep -rn 'swiftc .*swift/\*\.swift' /tmp/k8-subtraction-probe.sh >/dev/null ||
    die "the subtraction grep can find a one-command swiftc build when there is one"
rm -f /tmp/k8-subtraction-probe.sh
ok "the subtraction check is able to fail"

grep -rn 'Quick type-check without installing' CLAUDE.md AGENTS.md >/dev/null &&
    die "the quick type-check command is gone from both instruction files"
ok "the quick type-check command is gone"

# install.sh and the QA installer build the app and nothing else, so neither may
# name a bare `swiftc` any more. `-Xswiftc`, which hands one flag through to the
# compiler, is a legitimate Swift Package Manager argument and is not a bare
# `swiftc`, which is why this is not the grep at the top of the file. The test
# harness is different: compile_only rightly keeps calling swiftc to compile a
# handful of files with one suite's test, so what is checked there is the two
# functions that build the app (below).
python3 - <<'PY' || die "install.sh and the QA installer name no bare swiftc command"
import re, pathlib
bare = re.compile(r'(?<!-X)\bswiftc\b')
assert bare.search("swiftc swift/*.swift -framework Cocoa"), "the search finds a bare swiftc"
assert not bare.search("swift build -Xswiftc -suppress-warnings"), "-Xswiftc is not a bare swiftc"
found = [f"{name}:{n}: {line.strip()}"
         for name in ("install.sh", "scripts/install-agent-harness-qa.sh")
         for n, line in enumerate(pathlib.Path(name).read_text().split("\n"), 1)
         if bare.search(line)]
assert not found, found
PY
ok "install.sh and the QA installer name no bare swiftc command, and the search can find one"

# The Global Constraints call the signature and the swap load-bearing: "A build
# that loses the signing identity or the grants is a failure." Nothing else in
# the gate reads install.sh's signing block, so these guards do. Each of them is
# taken out of a copy below, so none can quietly stop checking.
signing_and_swap_guards() { # <a copy of install.sh>; prints what is missing
    local file="$1"
    grep -q 'VF_ADHOC' "$file" ||
        echo "the VF_ADHOC guard is gone, so a build without a Developer ID would sign ad-hoc and reset every TCC grant"
    /usr/bin/awk '
        index($0, "\"${VF_ADHOC:-}\" != \"1\"") { window = 8; next }
        window > 0 { window--; if ($0 ~ /^ *exit 1$/) refused = 1 }
        END { exit refused ? 0 : 1 }' "$file" ||
        echo "install.sh no longer exits 1 when there is no Developer ID identity and VF_ADHOC is unset"
    grep -q -- '--timestamp=none' "$file" ||
        echo "--timestamp=none is gone, so installing would depend on Apple's timestamp service"
    grep -q -- '--identifier "com.voiceflow.app"' "$file" ||
        echo "the executable is no longer signed with the identifier com.voiceflow.app"
    grep -q -- 'codesign --force --deep' "$file" ||
        echo "the finished bundle is no longer deep-signed"
    grep -q -- 'codesign --verify --deep --strict "$BUILD_DEST"' "$file" ||
        echo "the finished bundle is no longer verified"
    grep -q 'PREVIOUS="$APP_DEST.previous"' "$file" ||
        echo "the swap no longer renames the installed bundle aside"
    grep -q 'mv "$APP_DEST" "$PREVIOUS"' "$file" ||
        echo "the installed bundle is no longer renamed aside before the new one lands"
    grep -q 'mv "$BUILD_DEST" "$APP_DEST"' "$file" ||
        echo "the staged bundle is no longer renamed into place"
    grep -qE 'rm -rf "\$APP_DEST"( |$)' "$file" &&
        echo "the installed bundle is deleted rather than renamed aside, so a failed swap leaves nothing installed"
    return 0
}

MISSING="$(signing_and_swap_guards install.sh)"
[ -z "$MISSING" ] || die "install.sh keeps its signing and swap behaviour: $MISSING"
ok "install.sh still refuses an unsigned build, signs and verifies the bundle, and swaps it in with two renames"

# Each guard must be able to fail. Every mutation below is one the review made
# by hand while the whole gate stayed green.
PROBE="$(mktemp -d /tmp/k8-install-guard-probe.XXXXXX)"
while IFS='|' read -r label expression; do
    [ -n "$label" ] || continue
    sed "$expression" install.sh > "$PROBE/install.sh"
    [ -n "$(signing_and_swap_guards "$PROBE/install.sh")" ] ||
        die "the signing and swap guards must go red when $label"
done <<'MUTATIONS'
the VF_ADHOC refusal is removed|/VF_ADHOC/d
the timestamp argument is dropped|s/--timestamp=none//
the bundle identifier is dropped|s/--identifier "com.voiceflow.app"//
the deep verification is deleted|/codesign --verify --deep --strict/d
the two-rename swap becomes a delete|s@^PREVIOUS="\$APP_DEST.previous"$@rm -rf "$APP_DEST"@
the staged bundle is copied instead of renamed|s@^mv "\$BUILD_DEST" "\$APP_DEST"$@cp -R "$BUILD_DEST" "$APP_DEST"@
MUTATIONS
rm -rf "$PROBE"
ok "each of those guards goes red when the behaviour it protects is taken out"

python3 - <<'PY' || die "compile_app and compile_qa_app build with Swift Package Manager"
import re, pathlib
text = pathlib.Path("scripts/test-agent-harness.sh").read_text()
for name in ("compile_app", "compile_qa_app"):
    body = re.search(rf"^{name}\(\) \{{(.*?)^\}}", text, re.S | re.M)
    assert body, name
    assert "swift build" in body.group(1), name
    assert not re.search(r'(?<!-X)\bswiftc\b', body.group(1)), name
PY
ok "compile_app and compile_qa_app build with Swift Package Manager"

echo "all $PASS checks passed"
