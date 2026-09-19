#!/bin/bash
# The persona store, built the way the app is built: it needs GRDB, Yams and V4's git runner.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
swiftc -o /tmp/vf-persona-store -I "$BIN/Modules" -L "$BIN" \
    swift/VoiceFlowPaths.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Contract/CleanText.swift \
    swift/Store/Database.swift swift/Store/Migrations.swift \
    swift/Git/GitProgram.swift swift/Git/GitRunner.swift swift/Git/GitRevision.swift \
    swift/Personas/PersonaPaths.swift swift/Personas/PersonaFormat.swift \
    swift/Personas/PersonaIssue.swift swift/Personas/PersonaFrontMatter.swift \
    swift/Personas/PersonaHeader.swift swift/Personas/PersonaSnapshot.swift \
    swift/Personas/PersonaChecker.swift swift/Personas/PersonaHistory.swift \
    swift/Personas/PersonaTemplates.swift swift/Personas/PersonaStore.swift \
    swift/Personas/PersonaRecords.swift \
    tests/persona_store/main.swift \
    -lGRDB -lYams -suppress-warnings
/tmp/vf-persona-store
