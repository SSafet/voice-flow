#!/bin/bash
# The persona_records table and the record fingerprint, built the way the app is built.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
swiftc -o /tmp/vf-persona-records -I "$BIN/Modules" -L "$BIN" \
    swift/VoiceFlowPaths.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Store/Database.swift swift/Store/Migrations.swift \
    swift/Personas/PersonaPaths.swift swift/Personas/PersonaRecords.swift \
    tests/persona_records/main.swift \
    -lGRDB -suppress-warnings
/tmp/vf-persona-records
