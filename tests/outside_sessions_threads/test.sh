#!/bin/bash
# Work package V8 — outside_sessions_threads. See tests/outside_sessions/common.sh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=../outside_sessions/common.sh
. "$REPO_ROOT/tests/outside_sessions/common.sh"
build_and_run_unit_suite outside_sessions_threads "$REPO_ROOT"
