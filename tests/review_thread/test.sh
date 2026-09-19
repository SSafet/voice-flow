#!/bin/bash
# ReviewThread. No database: the thread store is a fake sink that conforms to
# ReviewThreadSink, so this suite compiles its own named sources with swiftc.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

OUTPUT="$(mktemp -d /tmp/vf-review-thread.XXXXXX)/run"
trap 'rm -rf "$(dirname "$OUTPUT")"' EXIT
swiftc -o "$OUTPUT" \
    swift/Generated/PlatformContracts.swift \
    swift/Captured/Review/ReviewThread.swift \
    tests/review_thread/main.swift \
    -suppress-warnings
"$OUTPUT"
