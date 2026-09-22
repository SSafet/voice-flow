#!/bin/bash
# Isolated signed-app V1 recovery acceptance. No production app/port/root.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$REPO_ROOT/tests/thread_store_damage_drill.py" "$@"
