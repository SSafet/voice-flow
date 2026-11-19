# Voice Flow module map

## Module map (`swift/`)

| File | Key types | Responsibility |
|------|-----------|----------------|
| `main.swift` | — | Entry point: `NSApplication` + `AppDelegate`. |
| `App.swift` | `AppDelegate` | Owns & wires everything: components, hotkeys, capability-first capture/delivery, TTS flow, agent session, windows. Its members are internal (not `private`) where the three extension files below need them. |
| `App+MCPTools.swift` | `extension AppDelegate` | `handleMCPTool` and every MCP tool handler (talking, overlays, captures); runs on HTTP threads, hops to main for UI. |
| `App+AgentsDataSource.swift` | `extension AppDelegate: AgentsDataSource` | The panel's window onto sessions, threads, assistants, automations, system agents: rows, details, actions. |
| `App+QA.swift` | `extension AppDelegate` (QA build only) | The `/__qa/*` control endpoints the signed test build serves for `tests/e2e_agent_harness.py`. |
| `CaptureRouting.swift` | `CaptureRun`, `CaptureRouter`, `CaptureCorrelation` | Immutable per-run capability/route state and UUID-based async callback correlation. |
| `CaptureClipboard.swift` | `CaptureClipboard` | One-item plain/HTML/RTFD serialization for copying capture text with embedded image evidence. |
| `WindowPlacement.swift` | `PanelAnchor`, `AnchoredPanelPlacement` | Same-display pill→ChatPanel geometry with visible-frame clamping. |
| `Core.swift` | `UserSettings`, `KeychainStore`, `HotkeyManager`, `AudioRecorder`, `BackendBridge`, `Paster`, `HotkeySpec` | Audio capture, Python STT bridge (subprocess), paste/stream into the frontmost app, settings, global hotkeys. |
| `UI.swift` | `Theme`, `MenuBarManager`, `FloatingIndicator`, `FloatingTranscriptPanel`, `MessagesView`, `DictationsView`, `TTSView`, `HoverCardView`, `KeyRecorderButton` | Menu bar, pill, live transcript overlay, and the Messages/Dictations/Speech tab surfaces. |
| `Panel.swift` | `ChatPanel`, `KeyablePanel`, `ChatTab` | The primary floating panel, its tabs, and the header; routes assistant state into `AgentsView` rather than rendering a chat itself. |
| `ReplyBubble.swift` | `ReplyBubble` | Facade over the pill's grown surface (no window of its own) — forwards messages/asks/streaming to `FloatingIndicator`. |
| `Capture.swift` | `CaptureStore`, `CaptureSummary`, `CaptureBundleMeta` | Capture bundles on disk (session frames + transcript) and ad-hoc screenshot saving. |
| `Inbox.swift` | `MessageInbox`, `InboxMessage` | Persistent queue of contextual-capture messages for Codex (check/wait semantics). |
| `Watcher.swift` | `WorkflowWatcher` | Ambient 5 s screen/app log feeding the nightly workflow review. |
| `Overlay.swift` | `OverlayManager`, `OverlayDoc`, `OverlayShape`, `OverlayBlock` | File-backed on-screen elements: guides, info panels, annotation shapes; watches `overlays/*.json`. |
| `MCP.swift` | `MCPServer` | MCP Streamable-HTTP endpoint + tool catalog for Codex. |
| `Agent.swift` | `AgentSession`, `ComputerControl` | LLM loop that reasons over screenshots and issues screen-control tool calls. |
| `AgentRuntime*.swift`, `CodexAgentRuntime.swift`, `OpenCodeAgentRuntime.swift` | `AgentRuntime`, `AgentTurnRequest`, `RuntimeBinding` | Runtime-neutral turn contract, canonical event/result types, and Codex/OpenCode adapters. |
| `OpenCodeSupervisor.swift`, `OpenCodeHTTPClient.swift` | `OpenCodeSupervisor`, `OpenCodeConnection`, `OpenCodeHTTPClient` | Pinned authenticated server lifecycle, isolated config, SSE/HTTP normalization, cancellation, restart, and process-tree cleanup. |
| `ModelGateway.swift` | `ModelGatewayServer`, `ModelGatewayCredentials` | Loopback OpenAI-compatible credential boundary, model/budget/token limits, and redaction. |
| `AgentTools.swift`, `AgentToolServer.swift`, `AgentPermissionPolicy.swift` | `AgentToolDispatcher`, `AgentToolSessionRegistry`, `AgentPermissionPolicy` | Five private tool families, strict schemas/session capabilities, projection, permissions, and audit. |
| `AgentCapabilities.swift`, `AgentPromptComposer.swift` | `AgentMemoryStore`, `AgentSkillStore`, `AgentPromptComposer` | Bounded memory revisions, selected-skill validation/projection, and runtime-parity prompt layers. |
| `AgentJobStore.swift`, `AgentSupervisor.swift`, `AgentRuntimeJobExecutor.swift` | `AgentJobStore`, `AgentSupervisor`, `AgentRuntimeJobExecutor` | SQLite jobs/runs/events, leases, fair concurrency, retries, budgets, triggers, and durable background execution. |
| `AgentsView.swift` | `AgentsView` | Assistant threads, runtime selector, durable job status, create/cancel/delete controls. |
| `VoiceFlowPaths.swift`, `QAControl.swift` | `VoiceFlowPaths`, `QAEventRecorder` | Config-root isolation plus the compile-time-absent QA authority/event plane. |
| `AssistantContinuity.swift` | `AssistantContinuityClassifier`, `LocalAssistantSessionAdapter` | Ephemeral current-vs-new wake routing and the stable local picker identity for FLORA. |
| `AssistantHistory.swift` | `AssistantHistoryStore`, `AssistantConversation`, `AssistantHistoryMessage` | Atomic local history and resume metadata for selectable in-app Assistant sessions. |
| `Composer.swift` | `ComposerView`, `ComposerControls` | The one message input, styled as a session bar and pinned under the thread (never inside the scroll): image chips, auto-growing text, and a bottom row — left: access mode (Observe · Workspace · Full access = the capability dial), + attach images, mic (dictate into this thread), snap; right: spinner + live status, runtime (Codex · OpenCode · Claude Code), model (Codex's own catalog / Sonnet-Opus-Haiku / OpenRouter), reasoning effort, and Send that becomes Stop while a turn runs. It stays up during the turn so a draft is kept. Assistant threads configure the bar; MCP threads get the plain one. Do not hand-build another. |
| `Codex.swift` | `CodexExecBackend` | `codex exec --json` per-turn backend: the continuity router's one-shot classifier and the fallback when the app-server cannot start. |
| `CodexAppServer.swift` | `CodexAppServerBackend`, `CodexAppServerProtocol`, `ProcessTree` | The default Codex backend: one long-lived `codex app-server` JSON-RPC process — thread/start + thread/resume, turn/start, streamed `item/agentMessage/delta`, request-based interrupt. A dead thread starts fresh with the canonical handoff. |
| `ClaudeCode.swift` | `ClaudeCodeAgentRuntime`, `ClaudeCodeProtocol` | Claude-subscription turns via `claude -p` with stream-json in/out (session id per conversation, `--resume`, base64 images on stdin, `--permission-mode` from the trust profile, `--effort` from the shared ladder). |
| `Annotation.swift` | `AnnotationOverlay` | Draw-on-screen overlay (pen + multiline text notes with size presets). |
| `Settings.swift` | `SettingsStore`, `SettingsWindowController`, `PermissionsWindowController`, `KeyRecorderView` | SwiftUI settings & permissions windows. |
| `ScreenCapture.swift` | `ScreenCapture`, `CaptureScheduler`, `ImageUtils` | ScreenCaptureKit screenshots for the agent. |
| `TTS.swift` | `TTSController`, `TTSRequest`, `TTSStatusSnapshot`, `AgentReplySpeaker`, `LocalAPIServer`, `OpenAITTSVoices` | Text-to-speech engine (incl. live-fed streaming speech) + a localhost HTTP control API. |
