#!/usr/bin/env bash
# Builds the proof, assembles the two application bundles and runs both of them.
# The first bundle carries the transport-security exception for `localhost`; the
# second carries no transport-security key at all. Exits non-zero when either run
# has a failed check.
set -euo pipefail

package="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-/tmp/k7-proof}"
port="${PROOF_PORT:-8799}"
preview_port="${PROOF_PREVIEW_PORT:-8798}"

swift build --package-path "$package" -c release
binary="$package/.build/release/loopback-proof"

status=0
for variant in with-exception no-exception; do
    app="$out/LoopbackProof-$variant.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$package/bundle/Info-$variant.plist" "$app/Contents/Info.plist"
    cp "$binary" "$app/Contents/MacOS/loopback-proof"
    codesign --force --sign - "$app"
    echo "=== $variant"
    if "$app/Contents/MacOS/loopback-proof" --port "$port" --preview-port "$preview_port" --out "$out/$variant"; then
        echo "$variant: every check passed"
    else
        echo "$variant: a check failed"
        status=1
    fi
done
exit $status
