#!/bin/bash
# The persona format, built with Yams because the header is read with it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
swift build -c debug -Xswiftc -suppress-warnings >/dev/null
BIN="$(swift build -c debug --show-bin-path)"
swiftc -o /tmp/vf-persona-format -I "$BIN/Modules" -L "$BIN" \
    swift/VoiceFlowPaths.swift \
    swift/Generated/PlatformContracts.swift \
    swift/Personas/PersonaPaths.swift swift/Personas/PersonaFormat.swift \
    swift/Personas/PersonaIssue.swift swift/Personas/PersonaFrontMatter.swift \
    swift/Personas/PersonaHeader.swift swift/Personas/PersonaSnapshot.swift \
    swift/Personas/PersonaChecker.swift \
    tests/persona_format/main.swift \
    -lYams -suppress-warnings
/tmp/vf-persona-format
