#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO_ROOT/tests/thread_store_common.sh"
build_and_run_store_suite thread_store "$REPO_ROOT"
