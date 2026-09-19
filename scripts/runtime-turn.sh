#!/bin/bash
# The temporary command-line caller for work package V3.
#
#   scripts/runtime-turn.sh --runtime codex|claude|opencode \
#       --project <folder> --prompt <text> [--persona <folder>] \
#       [--trust observe|workspace|unattended] [--model <id>] \
#       [--tool-endpoint <url>] [--tool-token <token>]
#
# It compiles tools/runtime-turn/main.swift against the runtime sources and
# runs it, one turn per runtime, until V6's server can drive the same path.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
export VOICE_FLOW_QA_PORT="${VOICE_FLOW_QA_PORT:-18793}"

XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
[ -d "$XCODE_SDK" ] || XCODE_SDK="$(xcrun --show-sdk-path)"

BUILD_DIR="$(mktemp -d /tmp/vf-runtime-turn.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

SOURCES=(
    swift/VoiceFlowPaths.swift
    swift/AgentRuntimeTypes.swift
    swift/AgentRuntime.swift
    swift/AgentPermissionPolicy.swift
    swift/AgentCapabilities.swift
    swift/AgentPromptComposer.swift
    swift/DailyFocus.swift
    swift/AgentTools.swift
    swift/Sandbox.swift
    swift/Generated/PlatformContracts.swift
    swift/Contract/CleanText.swift
    swift/Runtimes/RuntimeFolders.swift
    swift/Runtimes/RuntimeGrants.swift
    swift/Runtimes/RuntimeLaunchError.swift
    swift/Runtimes/RuntimeRuleFile.swift
    swift/Runtimes/RuntimeVersion.swift
    swift/Runtimes/RuntimeHealth.swift
    swift/Runtimes/RuntimeLauncher.swift
    swift/Runtimes/RuntimeSkills.swift
    swift/Runtimes/CodexLaunch.swift
    swift/Runtimes/CodexProcessPool.swift
    swift/Runtimes/ClaudeCodeLaunch.swift
    swift/Runtimes/OpenCodeLaunch.swift
    swift/Runtimes/Normaliser/RuntimeEvent.swift
    swift/Runtimes/Normaliser/CodexNormaliser.swift
    swift/Runtimes/Normaliser/ClaudeCodeNormaliser.swift
    swift/Runtimes/Normaliser/OpenCodeNormaliser.swift
)

swiftc "${SOURCES[@]}" tools/runtime-turn/main.swift \
    -sdk "$XCODE_SDK" -suppress-warnings -o "$BUILD_DIR/runtime-turn"

"$BUILD_DIR/runtime-turn" "$@"
