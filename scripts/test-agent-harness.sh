#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---unit}"
BUILD_DIR="$(mktemp -d /tmp/voice-flow-tests.XXXXXX)"
UPSTREAM_PID=""
cleanup() {
    status=$?
    if [ -n "${VOICE_FLOW_TEST_ARTIFACTS:-}" ] && [ -d "$BUILD_DIR/e2e-artifacts" ]; then
        mkdir -p "$VOICE_FLOW_TEST_ARTIFACTS"
        cp -R "$BUILD_DIR/e2e-artifacts/." "$VOICE_FLOW_TEST_ARTIFACTS/"
    fi
    if [ -n "$UPSTREAM_PID" ]; then kill "$UPSTREAM_PID" 2>/dev/null || true; fi
    # A force-interrupted Swift live probe can exit before its async defer runs,
    # reparenting the bundled OpenCode server. The supervisor records ownership
    # under this harness's unique root; validate that exact process before kill.
    while IFS= read -r pid_file; do
        pid="$(tr -cd '0-9' < "$pid_file")"
        [ -n "$pid" ] && [ "$pid" -gt 1 ] || continue
        command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$command" in
            "$BUILD_DIR"*/opencode\ --pure\ serve*) kill "$pid" 2>/dev/null || true ;;
        esac
    done < <(find "$BUILD_DIR" -path '*/runtime/opencode/*/process.pid' -type f 2>/dev/null)
    rm -rf "$BUILD_DIR"
    return "$status"
}
trap cleanup EXIT

XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [ ! -d "$XCODE_SDK" ]; then
    XCODE_SDK="$(xcrun --show-sdk-path)"
fi

export SWIFT_MODULECACHE_PATH="$BUILD_DIR/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/clang-module-cache"
export VOICE_FLOW_CONFIG_ROOT="$BUILD_DIR/config"

compile_and_run() {
    local name="$1"
    shift
    swiftc "$@" -sdk "$XCODE_SDK" -suppress-warnings -o "$BUILD_DIR/$name"
    "$BUILD_DIR/$name"
}

compile_only() {
    local name="$1"
    shift
    swiftc "$@" -sdk "$XCODE_SDK" -suppress-warnings -o "$BUILD_DIR/$name"
}

compile_app() {
    swiftc "$PROJECT_DIR"/swift/*.swift \
        -framework Cocoa -framework AVFoundation -framework CoreGraphics \
        -framework ApplicationServices -framework Accelerate -framework Security \
        -framework ScreenCaptureKit -lsqlite3 -sdk "$XCODE_SDK" -O -suppress-warnings \
        -o "$BUILD_DIR/voice-flow"
}

compile_qa_app() {
    swiftc "$PROJECT_DIR"/swift/*.swift -D VOICE_FLOW_QA \
        -framework Cocoa -framework AVFoundation -framework CoreGraphics \
        -framework ApplicationServices -framework Accelerate -framework Security \
        -framework ScreenCaptureKit -lsqlite3 -sdk "$XCODE_SDK" -O -suppress-warnings \
        -o "$BUILD_DIR/voice-flow-qa"
}

APP_SUPPORT_SOURCES=()
for source in "$PROJECT_DIR"/swift/*.swift; do
    if [ "$(basename "$source")" != "main.swift" ]; then
        APP_SUPPORT_SOURCES+=("$source")
    fi
done

cd "$PROJECT_DIR"
if [ "$MODE" = "--release" ]; then
    python3 tests/validate_capability_catalog.py --release
else
    python3 tests/validate_capability_catalog.py
fi
python3 tests/validate_runtime_manifest.py
compile_app
if strings -a "$BUILD_DIR/voice-flow" | grep -F 'QA capability required' >/dev/null; then
    echo "release binary contains QA control routes" >&2
    exit 1
fi
compile_qa_app
if ! strings -a "$BUILD_DIR/voice-flow-qa" | grep -F 'QA capability required' >/dev/null; then
    echo "QA binary is missing its control plane" >&2
    exit 1
fi

compile_and_run voice_flow_paths swift/VoiceFlowPaths.swift tests/voice_flow_paths/main.swift
compile_and_run assistant_wake swift/AssistantWake.swift tests/assistant_wake/main.swift
compile_and_run capture_routing swift/CaptureRouting.swift tests/capture_routing/main.swift
compile_and_run display_context swift/DisplayContext.swift tests/display_context/main.swift -framework Cocoa -framework CoreGraphics
compile_and_run window_placement swift/WindowPlacement.swift tests/window_placement/main.swift -framework Cocoa
compile_and_run agents_navigation swift/AgentsNavigation.swift tests/agents_navigation/main.swift
compile_and_run capture_clipboard swift/CaptureClipboard.swift tests/capture_clipboard/main.swift -framework Cocoa
compile_and_run capture_store swift/VoiceFlowPaths.swift swift/DisplayContext.swift \
    swift/ScreenCapture.swift swift/Capture.swift tests/capture_store/main.swift \
    -framework Cocoa -framework ScreenCaptureKit
compile_and_run player swift/Player.swift tests/player/main.swift
compile_and_run watcher_bus swift/VoiceFlowPaths.swift swift/WatcherPolicy.swift \
    swift/WatcherBus.swift tests/watcher_bus/main.swift
compile_and_run hotkey_precedence "${APP_SUPPORT_SOURCES[@]}" tests/hotkey_precedence/main.swift \
    -framework Cocoa -framework AVFoundation -framework CoreGraphics -framework ApplicationServices \
    -framework Accelerate -framework Security -framework ScreenCaptureKit
compile_and_run overlay_contracts "${APP_SUPPORT_SOURCES[@]}" tests/overlay_contracts/main.swift \
    -framework Cocoa -framework AVFoundation -framework CoreGraphics -framework ApplicationServices \
    -framework Accelerate -framework Security -framework ScreenCaptureKit -lsqlite3
compile_and_run assistants swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift tests/assistants/main.swift
compile_and_run agent_capabilities swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentCapabilities.swift tests/agent_capabilities/main.swift
compile_and_run agent_prompt swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentRuntimeTypes.swift swift/AssistantHistory.swift swift/AgentCapabilities.swift \
    swift/AgentPromptComposer.swift tests/agent_prompt/main.swift
compile_and_run agent_permissions swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentRuntimeTypes.swift swift/AgentCapabilities.swift swift/AgentPermissionPolicy.swift \
    tests/agent_permissions/main.swift
compile_and_run qa_control -D VOICE_FLOW_QA swift/VoiceFlowPaths.swift \
    swift/AssistantWake.swift swift/Assistants.swift swift/AgentRuntimeTypes.swift \
    swift/AgentCapabilities.swift swift/QAControl.swift \
    tests/qa_control/main.swift -framework Security
compile_and_run agent_tools swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentRuntimeTypes.swift swift/AgentCapabilities.swift swift/AgentPermissionPolicy.swift \
    swift/AgentTools.swift tests/agent_tools/main.swift
compile_and_run agent_jobs swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentRuntimeTypes.swift swift/AgentCapabilities.swift swift/AgentJobStore.swift \
    tests/agent_jobs/main.swift -lsqlite3
compile_and_run openrouter_models swift/VoiceFlowPaths.swift swift/OpenRouterModels.swift \
    tests/openrouter_models/main.swift
compile_and_run openrouter_model_picker swift/VoiceFlowPaths.swift swift/OpenRouterModels.swift \
    swift/OpenRouterModelPicker.swift swift/AgentJobEditor.swift \
    tests/openrouter_model_picker/main.swift -framework Cocoa
compile_and_run agent_supervisor swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentRuntimeTypes.swift swift/AssistantHistory.swift swift/AgentRuntime.swift \
    swift/AgentCapabilities.swift swift/AgentJobStore.swift swift/AgentSupervisor.swift \
    tests/agent_supervisor/main.swift -lsqlite3
compile_and_run assistant_history swift/VoiceFlowPaths.swift swift/AgentRuntimeTypes.swift \
    swift/AssistantHistory.swift tests/assistant_history/main.swift
compile_and_run assistant_continuity swift/VoiceFlowPaths.swift swift/AgentRuntimeTypes.swift swift/AssistantHistory.swift \
    swift/AssistantContinuity.swift tests/assistant_continuity/main.swift
compile_and_run codex_runtime swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentRuntimeTypes.swift swift/AssistantHistory.swift swift/AgentRuntime.swift swift/Codex.swift \
    swift/CodexAgentRuntime.swift tests/codex_runtime/main.swift
compile_and_run opencode_runtime swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentRuntimeTypes.swift swift/AssistantHistory.swift swift/AgentRuntime.swift \
    swift/AgentCapabilities.swift swift/AgentPromptComposer.swift swift/AgentPermissionPolicy.swift swift/AgentTools.swift swift/AgentToolServer.swift \
    swift/ModelGateway.swift swift/OpenRouterModels.swift swift/OpenCodeSupervisor.swift swift/OpenCodeHTTPClient.swift swift/OpenCodeAgentRuntime.swift \
    tests/opencode_runtime/main.swift -framework Security
compile_and_run opencode_http swift/VoiceFlowPaths.swift swift/AssistantWake.swift swift/Assistants.swift \
    swift/AgentRuntimeTypes.swift swift/AssistantHistory.swift swift/AgentRuntime.swift \
    swift/AgentCapabilities.swift swift/AgentPermissionPolicy.swift swift/AgentTools.swift \
    swift/AgentToolServer.swift swift/ModelGateway.swift swift/OpenRouterModels.swift swift/OpenCodeSupervisor.swift \
    swift/OpenCodeHTTPClient.swift tests/opencode_http/main.swift -framework Security

"$PROJECT_DIR/.venv/bin/python" tests/test_backend_protocol.py -q

case "$MODE" in
    --unit) ;;
    --live|--e2e|--nightly|--release)
        "$PROJECT_DIR/scripts/prepare-opencode-runtime.sh" "$BUILD_DIR/Runtime/OpenCode"
        compile_only model_gateway swift/VoiceFlowPaths.swift swift/AssistantWake.swift \
            swift/Assistants.swift swift/AgentRuntimeTypes.swift swift/AgentCapabilities.swift \
            swift/ModelGateway.swift tests/model_gateway/main.swift \
            -framework Security
        PORT_FILE="$BUILD_DIR/upstream-port"
        python3 tests/fake_openai_server.py --port-file "$PORT_FILE" &
        UPSTREAM_PID=$!
        for _ in $(seq 1 100); do
            [ -s "$PORT_FILE" ] && break
            sleep 0.02
        done
        [ -s "$PORT_FILE" ] || { echo "fake provider did not start" >&2; exit 1; }
        UPSTREAM_PORT="$(<"$PORT_FILE")"
        VOICE_FLOW_TEST_UPSTREAM="http://127.0.0.1:$UPSTREAM_PORT/v1" "$BUILD_DIR/model_gateway"
        kill "$UPSTREAM_PID" 2>/dev/null || true
        UPSTREAM_PID=""
        compile_and_run agent_tool_server swift/VoiceFlowPaths.swift swift/AssistantWake.swift \
            swift/Assistants.swift swift/AgentRuntimeTypes.swift swift/AgentCapabilities.swift \
            swift/AgentPermissionPolicy.swift swift/AgentTools.swift swift/AgentToolServer.swift \
            tests/agent_tool_server/main.swift -framework Security
        PORT_FILE="$BUILD_DIR/opencode-upstream-port"
        python3 tests/fake_openai_server.py --port-file "$PORT_FILE" &
        UPSTREAM_PID=$!
        for _ in $(seq 1 100); do
            [ -s "$PORT_FILE" ] && break
            sleep 0.02
        done
        [ -s "$PORT_FILE" ] || { echo "OpenCode fake provider did not start" >&2; exit 1; }
        UPSTREAM_PORT="$(<"$PORT_FILE")"
        compile_only opencode_live_turn swift/VoiceFlowPaths.swift swift/AssistantWake.swift \
            swift/Assistants.swift swift/AgentRuntimeTypes.swift swift/AssistantHistory.swift \
            swift/AgentRuntime.swift swift/AgentCapabilities.swift swift/AgentPermissionPolicy.swift \
            swift/AgentPromptComposer.swift swift/AgentTools.swift swift/AgentToolServer.swift swift/ModelGateway.swift swift/OpenRouterModels.swift \
            swift/OpenCodeSupervisor.swift swift/OpenCodeHTTPClient.swift swift/OpenCodeAgentRuntime.swift \
            tests/opencode_live_turn/main.swift -framework Security
        VOICE_FLOW_TEST_UPSTREAM="http://127.0.0.1:$UPSTREAM_PORT/v1" \
            VOICE_FLOW_CANARY_OPENCODE_REPORT="$BUILD_DIR/opencode-canary.json" \
            "$BUILD_DIR/opencode_live_turn"
        kill "$UPSTREAM_PID" 2>/dev/null || true
        UPSTREAM_PID=""
        compile_and_run opencode_supervisor swift/VoiceFlowPaths.swift swift/AgentRuntimeTypes.swift \
            swift/AssistantHistory.swift swift/AgentRuntime.swift \
            swift/AssistantWake.swift swift/Assistants.swift swift/AgentCapabilities.swift \
            swift/AgentPermissionPolicy.swift swift/AgentTools.swift swift/AgentToolServer.swift \
            swift/ModelGateway.swift swift/OpenRouterModels.swift swift/OpenCodeSupervisor.swift tests/opencode_supervisor/main.swift -framework Security
        compile_only codex_live_turn swift/Codex.swift tests/codex_live_turn/main.swift
        VOICE_FLOW_CONFIG_ROOT="$BUILD_DIR/codex-live-config" \
            VOICE_FLOW_CANARY_CODEX_REPORT="$BUILD_DIR/codex-canary.json" \
            "$BUILD_DIR/codex_live_turn"
        python3 tests/compare_runtime_canary.py \
            --codex "$BUILD_DIR/codex-canary.json" \
            --opencode "$BUILD_DIR/opencode-canary.json" \
            --out "$BUILD_DIR/runtime-canary-report.json"
        if [ "$MODE" = "--e2e" ] || [ "$MODE" = "--nightly" ] || [ "$MODE" = "--release" ]; then
            QA_APP="$BUILD_DIR/Voice Flow QA.app"
            VF_ADHOC=1 VOICE_FLOW_QA_APP_DEST="$QA_APP" \
                "$PROJECT_DIR/scripts/install-agent-harness-qa.sh"
            python3 tests/validate_runtime_manifest.py --app "$QA_APP"
            SOAK_SECONDS=0
            if [ "$MODE" = "--nightly" ]; then SOAK_SECONDS=7200; fi
            if [ "$MODE" = "--release" ]; then SOAK_SECONDS=14400; fi
            python3 tests/e2e_agent_harness.py \
                --app "$QA_APP" \
                --root "$BUILD_DIR/signed-qa-root" \
                --repo "$PROJECT_DIR" \
                --artifacts "$BUILD_DIR/e2e-artifacts" \
                --soak-seconds "$SOAK_SECONDS"
            if [ -n "${VOICE_FLOW_TEST_ARTIFACTS:-}" ]; then
                mkdir -p "$VOICE_FLOW_TEST_ARTIFACTS"
                cp -R "$BUILD_DIR/e2e-artifacts/." "$VOICE_FLOW_TEST_ARTIFACTS/"
                cp "$BUILD_DIR/runtime-canary-report.json" \
                    "$VOICE_FLOW_TEST_ARTIFACTS/runtime-canary-report.json"
            fi
        fi
        ;;
    *)
        echo "usage: $0 [--unit|--live|--e2e|--nightly|--release]" >&2
        exit 2
        ;;
esac

EVIDENCE_MODE="${MODE#--}"
if [ "$EVIDENCE_MODE" = "nightly" ]; then EVIDENCE_MODE="e2e"; fi
EVIDENCE_PATH="${VOICE_FLOW_EVIDENCE_PATH:-/tmp/voice-flow-agent-evidence-$EVIDENCE_MODE.json}"
python3 tests/record_test_evidence.py --mode "$EVIDENCE_MODE" --out "$EVIDENCE_PATH"
if [ "$MODE" = "--release" ]; then
    python3 tests/validate_capability_catalog.py --release \
        --mode "$EVIDENCE_MODE" --evidence "$EVIDENCE_PATH"
else
    python3 tests/validate_capability_catalog.py \
        --mode "$EVIDENCE_MODE" --evidence "$EVIDENCE_PATH"
fi
echo "agent harness tests: $MODE gate passed"
