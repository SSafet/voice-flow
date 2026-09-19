#!/bin/bash
# The loopback server's core, compiled against only the Foundation-only files
# under swift/Server/LoopbackCore, so the suite needs no Hummingbird and no
# running app. Sources are named one by one: a file the task has not written yet
# is a compile error, which is the red the verification commit is supposed to be.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

SOURCES=(
    swift/Server/LoopbackCore/LoopbackPorts.swift
    swift/Server/LoopbackCore/LoopbackAccess.swift
    swift/Server/LoopbackCore/LoopbackTicketStore.swift
    swift/Server/LoopbackCore/LoopbackStaticRouter.swift
    swift/Server/LoopbackCore/LoopbackShellFiles.swift
    swift/Server/LoopbackCore/LoopbackMountPoint.swift
)

for source in "${SOURCES[@]}"; do
    [ -f "$source" ] || { echo "not ok - $source is not there yet" >&2; exit 1; }
done

xcrun swiftc "${SOURCES[@]}" tests/loopback_server/main.swift \
    -o /tmp/v6-loopback-server -suppress-warnings
/tmp/v6-loopback-server
