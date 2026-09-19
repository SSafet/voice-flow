#!/bin/bash
# The pinned ripgrep manifest is well formed, and the staged binary matches both
# its checksum and its version.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
STAGE="$(mktemp -d /tmp/vf-ripgrep-test.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
PASS=0
ok() { PASS=$((PASS + 1)); echo "ok $PASS - $1"; }
die() { echo "not ok - $1" >&2; exit 1; }

MANIFEST="runtime/ripgrep/versions.json"
[ -f "$MANIFEST" ] || die "the ripgrep manifest is there"
python3 - "$MANIFEST" <<'PY' || die "the manifest names a version, two architectures, two checksums each and a release address"
import json, re, sys
manifest = json.load(open(sys.argv[1]))
version = manifest["version"]
assert re.fullmatch(r"\d+\.\d+\.\d+", version), version
assert set(manifest["assets"]) == {"arm64", "x86_64"}
names = {"arm64": "aarch64-apple-darwin", "x86_64": "x86_64-apple-darwin"}
for architecture, asset in manifest["assets"].items():
    assert asset["url"] == (
        "https://github.com/BurntSushi/ripgrep/releases/download/"
        f"{version}/ripgrep-{version}-{names[architecture]}.tar.gz"
    ), asset["url"]
    for key in ("archiveSHA256", "binarySHA256"):
        assert re.fullmatch(r"[0-9a-f]{64}", asset[key]), (architecture, key)
PY
ok "the ripgrep manifest is well formed"

scripts/prepare-ripgrep-runtime.sh "$STAGE/ripgrep" >/dev/null
[ -x "$STAGE/ripgrep/rg" ] || die "the staged ripgrep is executable"
ok "prepare-ripgrep-runtime.sh stages an executable rg"

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$MANIFEST")"
REPORTED="$("$STAGE/ripgrep/rg" --version | head -n 1)"
case "$REPORTED" in
    "ripgrep $VERSION"*) ;;
    *) die "the staged ripgrep reports the pinned version, not: $REPORTED" ;;
esac
ok "the staged ripgrep reports the pinned version"

# A damaged binary must be refused, so the checksum check cannot pass vacuously.
# The override is the way to hand the script a binary without the network; a
# wrong one must end the run, not quietly send it to download a good one.
printf 'not ripgrep' > "$STAGE/broken"
if VOICE_FLOW_RIPGREP_BINARY="$STAGE/broken" \
        scripts/prepare-ripgrep-runtime.sh "$STAGE/again" >/dev/null 2>&1; then
    die "a binary whose checksum does not match must be refused"
fi
[ ! -e "$STAGE/again/rg" ] || die "the refused binary must not be left staged"
ok "a binary whose checksum does not match is refused"

echo "all $PASS checks passed"
