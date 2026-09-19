#!/bin/bash
# The thread protocol's carrier (01 §3.4, 06 §3.9), compiled against the
# Foundation-only loopback core and the generated contract types, so the suite
# needs no Hummingbird and no running app.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

[ -d swift/Server/LoopbackCore ] || { echo "not ok - swift/Server/LoopbackCore is not there yet" >&2; exit 1; }
[ -f swift/Server/LoopbackCore/ThreadRpc.swift ] || { echo "not ok - ThreadRpc.swift is not there yet" >&2; exit 1; }
[ -f swift/Generated/PlatformContracts.swift ] || { echo "not ok - the generated contract types are not there" >&2; exit 1; }

SOURCES=(swift/Generated/PlatformContracts.swift)
while IFS= read -r source; do SOURCES+=("$source"); done < <(find swift/Server/LoopbackCore -name '*.swift' | sort)

xcrun swiftc "${SOURCES[@]}" tests/loopback_thread/main.swift \
    -o /tmp/v6-loopback-thread -suppress-warnings
/tmp/v6-loopback-thread
