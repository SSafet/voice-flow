#!/bin/bash
# The retirement suite, compiled with swiftc because it needs nothing but
# Foundation: the step reads and moves files and hands dictations to a sink.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# The unit gate must run this suite, or a later change could take the
# retirement out again without anything turning red.
grep -Fq 'tests/data_sources_retirement/test.sh' scripts/test-agent-harness.sh || {
    echo "not ok - the harness does not run tests/data_sources_retirement/test.sh" >&2; exit 1; }
python3 - <<'PY' || exit 1
import json
registry = json.load(open("tests/test_registry.json"))
assert "data_sources_retirement" in registry["runners"]["unit"]["required_suites"], \
    "required_suites is missing data_sources_retirement"
entries = [t for t in registry["tests"] if t["id"] == "tests/data_sources_retirement/test.sh"]
assert entries, "no tests entry for tests/data_sources_retirement/test.sh"
assert entries[0]["runner"] == "unit", "the entry is not on the unit runner"
assert "data_sources_retirement" in entries[0]["suites"], "the entry names no data_sources_retirement suite"
PY

XCODE_SDK="$(xcrun --show-sdk-path)"
BIN="$(mktemp -d /tmp/vf-s6-retirement.XXXXXX)/retirement"
trap 'rm -rf "$(dirname "$BIN")"' EXIT
swiftc -sdk "$XCODE_SDK" -suppress-warnings \
    swift/Captured/Retirement/DataSourcesRetirement.swift \
    tests/data_sources_retirement/main.swift \
    -o "$BIN"
"$BIN"
