#!/bin/bash
# The tool host (06 §3.8), compiled against the existing permission-policy and
# assistant sources so the audit file is the real agent-security.jsonl writer.
# It needs no Hummingbird and no running app.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

SOURCES=(
    swift/VoiceFlowPaths.swift
    swift/AssistantWake.swift
    swift/Assistants.swift
    swift/AgentRuntimeTypes.swift
    swift/AgentCapabilities.swift
    swift/AgentSourceConfiguration.swift
    swift/AgentPermissionPolicy.swift
)
for source in "${SOURCES[@]}"; do
    [ -f "$source" ] || { echo "not ok - $source is not there yet" >&2; exit 1; }
done
[ -d swift/Tools ] || { echo "not ok - swift/Tools is not there yet" >&2; exit 1; }
[ -f swift/Tools/ToolHost.swift ] || { echo "not ok - swift/Tools/ToolHost.swift is not there yet" >&2; exit 1; }

while IFS= read -r source; do SOURCES+=("$source"); done < <(find swift/Tools -name '*.swift' | sort)

xcrun swiftc "${SOURCES[@]}" tests/tool_host/main.swift \
    -o /tmp/v6-tool-host -suppress-warnings
/tmp/v6-tool-host
