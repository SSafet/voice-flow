#!/bin/sh
set -eu
cd "$(dirname "$0")"
exec uv run --locked --python 3.11 python probe.py "$@"
