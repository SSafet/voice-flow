#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work="$(mktemp -d "${TMPDIR:-/tmp}/vf-native-authority.XXXXXX")"
trap 'rm -rf "$work"' EXIT
# Reuse a pinned dependency build when supplied; never rebuild/install the app.
if [ -z "${VOICE_FLOW_TEST_SPM_BIN:-}" ]; then
  swift build -c debug --target Hummingbird -j 2 >/dev/null
  swift build -c debug --target MCP -j 2 >/dev/null
  export VOICE_FLOW_TEST_SPM_BIN="$(swift build -c debug --show-bin-path)"
fi
python3 tests/native_authority_broker/compile.py "$work/proof"
"$work/proof"
