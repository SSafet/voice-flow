#!/bin/bash
# Work package V1 — thread_store_records. Built with Swift Package Manager because the thread
# store needs GRDB; see tests/thread_store_common.sh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$REPO_ROOT/tests/test_thread_store_runner.py" -q
# shellcheck source=../thread_store_common.sh
. "$REPO_ROOT/tests/thread_store_common.sh"
build_and_run_store_suite thread_store_records "$REPO_ROOT"
