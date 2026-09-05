# Voice Flow

A native macOS menu-bar app for **voice dictation**, **text-to-speech**, and an
**on-device screen agent**. The UI is hand-built AppKit (with a couple of SwiftUI
windows); dictation transcription runs in a bundled Python backend driven over a
subprocess pipe.

## Build & run

```bash
uv sync                 # once — creates .venv with the Python backend deps
./install.sh            # compiles swift/*.swift → "/Applications/Voice Flow.app", codesigns
open "/Applications/Voice Flow.app"
./uninstall.sh          # remove
./scripts/test-agent-harness.sh --unit     # deterministic compile + unit/contracts
./scripts/test-agent-harness.sh --live     # plus real Codex + pinned OpenCode smoke
./scripts/test-agent-harness.sh --e2e      # plus isolated signed-app computer QA
```

`install.sh` compiles every file in `swift/` into one binary and prefers a stable
**Developer ID** signing identity so macOS keeps TCC / Keychain grants across
rebuilds (falls back to ad-hoc, which resets permissions each build).

`--nightly` adds a two-hour three-agent soak. `--release` runs the complete
gate plus the four-hour soak and emits audited evidence for every ID in
`tests/capabilities.json` through `tests/test_registry.json`.

## Dual-runtime Assistant harness

Voice Flow owns the Assistant contract and canonical transcript. Each
conversation can select **Codex** or **OpenCode** between turns; Settings sets
only the default for new conversations. Codex remains a first-class rollback
path. A legacy `codexThreadId` expands into a dirty Codex runtime binding, so
the next turn safely reseeds from canonical history without losing rollback
readability.

OpenCode 1.17.11 is checksum-pinned in `runtime/opencode/versions.json`, copied
into the signed app, and run as one supervised `--pure` loopback server per
trust profile. Its XDG roots are isolated under the Voice Flow config root,
auto-update/sharing/subagents are disabled, concurrent cold starts coalesce,
and stop/cancel terminates the process tree. Long-lived provider credentials
stay in Keychain: a rotating loopback model-gateway token is all OpenCode sees.

Assistant folders remain canonical for persona, bounded `memory/core.md` and
`memory/ledger.md`, and selected `skills/<name>/SKILL.md`. Voice Flow projects
only selected skills and five narrow first-party tools into OpenCode:
`voiceflow_computer`, `voiceflow_context`, `voiceflow_overlay`,
`voiceflow_user`, and `voiceflow_memory`. These tools use a private rotating
capability endpoint and never enter the public MCP session registry. External
integrations remain deny-by-default MCP selections.

The **Agents** surface owns durable background work. Jobs, runs, leases,
heartbeats, retries, trigger idempotency, concurrency keys, budgets, maximum
runtime, cancellation, and visible blocked/failure results live in
`agent-jobs.sqlite`. Initial caps are three global agents, three OpenCode runs,
two Codex runs, and one active run per conversation/concurrency key.
Settings and each OpenCode automation use the same searchable, cached
OpenRouter model catalog. The user chooses a model and budget; Voice Flow reads
that model's context/output limits from the provider catalog and writes them
into OpenCode's private custom-provider config automatically.

Quick type-check without installing:

```bash
swiftc swift/*.swift -framework Cocoa -framework AVFoundation -framework CoreGraphics \
  -framework ApplicationServices -framework Accelerate -framework Security \
  -framework ScreenCaptureKit -sdk "$(xcrun --show-sdk-path)" -O -suppress-warnings -o /tmp/vf
```

## Data workspace (VF-64)

The main ChatPanel now uses a persistent workspace sidebar: Now, Inbox, Threads,
Data, Assistants, Automations, Speech, Settings. Default size is 920×680 points,
clamped to the pill display; the small layout is 720×540. The notification pill
is unchanged. Settings embeds the same SettingsStore-backed controls in the panel.

`DataSourceStore` / `SourceCollector` own a separate local registry and immutable
copies (`sources-registry.json`, `source-collection-status.json`,
`source-snapshots/`). Do not put user configuration under `sources/`: install.sh
owns and replaces that directory. Collection runs independently of the desktop
watcher: public HTTP websites, local text folders, EML/mbox exported-email folders,
and read projections of existing Voice Flow stores. Failed refreshes preserve the
last successful snapshot; skipped/limited content is visible.

`SourcesView` owns connection, inspection/history, source guidance, and recovery.
Assistant definitions and automation jobs persist explicit `selectedSourceIDs`
and `sourceAccessMode`. New automation forms copy the assistant selection once;
subsequent assistant changes never widen saved jobs. `AgentSourceContext` freezes
selected data and authored guidance for each turn. Missing sources fail visibly.

`reviewCopies` uses `SourceReviewRuntime`, an app-owned OpenRouter model request
through ModelGateway. No Codex/OpenCode process or action tools are started in
this mode. Normal mode retains existing runtime permissions; selecting a source
alone is not a security boundary. Source-review turns dirty runtime bindings so
returning to the normal runtime reseeds canonical history.

Design and proof map: `design/vf64/implementation-and-proof.md`.

## Primary surface: the ChatPanel

The app's main window is **`ChatPanel`** (`swift/Panel.swift`) — a borderless
floating panel anchored to the little pill (`FloatingIndicator`). It has two
tabs (`ChatTab`, default **Agents** on open):

- **Inbox** — everything the user said, with a destination: the dictation
  history (`DictationsView` in `swift/UI.swift`), filtered by destination chips.
- **Agents** — every agent talking to the user (`AgentsView` in
  `swift/AgentsView.swift`): one row per MCP session plus the assistant;
  opening a row shows that session's thread. The assistant conversation is
  **that same thread view** — the only assistant surface: its header row
  composer is a session bar pinned under the thread: access mode (the
  capability dial as one word), + attach, mic, snap on the left; live status,
  runtime (Codex · OpenCode · Claude Code), model, reasoning effort (the one
  shared setting), and Send/Stop on the right — and it stays up while the
  turn runs, so a draft typed meanwhile is kept. Model choices are per
  runtime: `codex_model` (from `~/.codex/models_cache.json`),
  `claude_code_model`, `agent_model` (OpenRouter). `ChatPanel` no longer owns a chat of its own; it routes
  (`openAssistantConversation`, `setActivity`, `addNote` → a 6 s strip).
  Its nav bar is **Now · Threads · Setup** (`AgentsDestination.navigation`):
  two reading surfaces, then one setup surface. The panel lands on **Now**,
  which answers "what is here for me?": NEEDS YOU (asks, blocked/failed
  automations), RUNNING NOW, and UNREAD (open threads with unseen output,
  newest first — `AgentsNowSnapshot` in `swift/AgentsNavigation.swift`).
  "All clear" appears only when all three are empty; the Now badge still
  counts asks/blocks only. **Setup** is assistants + the SYSTEM agents +
  automations on one screen (`buildSetup`); the `.automations` destination
  still exists for deep links and lights the Setup item, and the automation
  search field and filter chips appear only from 6 automations up.
  `AgentsView.refresh()` memoizes: on a read surface (destination, thread,
  search) identical row inputs skip the rebuild (`RefreshInputs`), so the
  ~20 refresh call sites cost nothing when nothing changed.
  The panel header's voice-replies / computer-control / Clear icons act on
  the assistant conversation and show only while it is on screen
  (`ChatPanel.updateHeaderScope`); Annotate and Settings are always there.
  Its **Assistants** sub-tab also carries a **SYSTEM** section: the three
  agents the app runs on its own behalf — continuity router, speech cleanup,
  and speech (`SystemAgentStore`, `swift/SystemAgents.swift`). Identities are
  fixed (no create/delete); model, reasoning, and the leading instructions
  brief are editable, and every call site resolves its config at call time so
  a change lands on the next run with no restart. The delimited data blocks
  and JSON schema around the brief stay in code — dropping them would turn
  each turn into a silent fallback. Each row's **Test now** runs the real path
  once and reports what came back. The speech agent's instructions are the
  existing `tts_instructions` setting, not a second copy.

**Speech** is a drawer, not a tab: the ♪ button overlays `TTSView` (paste text,
play it through the TTS engine) on whichever tab is current; an explicit tab
select closes it. `MessagesView` (`swift/UI.swift`) still exists but is
store-only — it writes the `messages.json` archive and is never added to the
view hierarchy. The menu-bar "Dictation History" item and the pill's context
menu open the panel on the Inbox tab.

## Hotkey-driven agent flows (no panel required)

The agent is meant to be driven by hotkeys, with the ChatPanel closed:

- **Dictate** (hold): voice → transcript. With a concrete assistant/session
  conversation visibly open, it goes there; otherwise it pastes into the app
  that owned focus when capture began.
- **Toggle Dictate to Inbox** (double-press): the same Dictate pipeline with
  external delivery disabled, so the result is kept in Dictations/Inbox.
- **Dictate + snapshot** (hold): Dictate plus one screenshot frozen at hotkey
  release. Outside a conversation it pastes a prompt containing the saved
  local image path.
- **Continuous dictate + snapshots** (toggle): records the mic continuously
  and buffers deduped screenshots (`CaptureScheduler`, plus a forced shot
  whenever annotate mode ends); on stop, everything becomes a **capture
  bundle** on disk (`CaptureStore`, see below) and follows the same contextual
  route.
- Overlapping bindings use longest-match precedence: if a modifier-only
  capture hotkey is held and a configured chord extends it (for example
  `Control+Shift` → `Control+Shift+1`), the prefix run is discarded and only
  the longer capability starts (`HotkeyPrecedence` / `HotkeyManager.onCancel`).
- Routing is capability-first: `CaptureRun` (`swift/CaptureRouting.swift`)
  freezes a UUID, visible conversation, pending interaction, and explicit
  paste target when capture begins. Screenshot/transcription callbacks join by
  UUID, so later UI/session/app changes cannot reroute an earlier result.
- A plain Dictate whose leading wake name resolves to FLORA runs a bounded
  binary continuity preflight (`AssistantContinuityClassifier`): reuse only
  the current FLORA conversation or create a fresh one, never select history.
  FLORA then appears as the stable local `assistant:flora` picker session.
  Closed-panel turns show only working/new-message receipts and unread state;
  the prompt and reply grow only after the user explicitly selects FLORA.
- **The pill IS the whole surface** (design spec: `design/pill-states.html`;
  one shape, nothing overlaid, dots never move). `FloatingIndicator` has four
  modes — `pill` (collapsed 52×18; middle dot grows to 9px and carries the
  active session number), `flash` (one-line receipts/errors,
  `flashMessage`), `picker` (`showPicker`: "sessions" + a numbered dot per
  session, active lit / pending amber, active name trailing; ⌃⌥1–6 or menu;
  collapses after ~4s, on any other hotkey, or click-anywhere), and `grown`
  (`showGrown`: amber title, selectable text, ask hint line, speaker/trash/✕
  icon cluster, live dots in the bottom band; streamed replies grow it live).
  Pushes queue **per session** (`sessionPushes`, a stack capped at 8;
  tool calls arriving with no `Mcp-Session-Id` are folded into a shared
  "anonymous" registry session so even degraded clients get a picker dot;
  consecutive identical re-sends collapse into one entry) and NEVER take
  the screen on arrival, no matter whose session: the user gets a one-line
  receipt ("name · new message — ⌃⌥N") plus the small pulsing unread ring
  around the number dot (`setUnreadIndicator`) until viewed. Reading happens
  by switching onto the session — ⌃⌥1–6 grows its whole stack (older pushes
  dim, newest bright; persists until ✕ while unseen, 5 s re-preview when
  already seen; `deliverPush`/`showPushStack` in `App.swift`) — or anytime
  in the panel's persistent Messages tab. Audio never auto-plays:
  re-selecting the already-active session reads its stack aloud
  (`double_select_speak` setting, toggle in Settings → Assistant), and the
  grown view's speaker icon does the same. `ReplyBubble` is now only a facade forwarding to the pill: ✕
  closes-and-keeps (asks stay pending, stacks survive; a "N sessions
  waiting" receipt flashes if others queued meanwhile), trash deletes
  stack AND session (cancels a waiting ask, drops the picker dot — a live
  session re-adopts on its next call), speaker reads aloud.
- With voice replies on (speaker toggle), `AgentReplySpeaker` (`swift/TTS.swift`)
  cuts the streaming reply at sentence boundaries into
  `TTSController.beginLiveSpeech/feedLiveSpeech/endLiveSpeech`, so speech starts
  before the reply finishes. The read-aloud hotkey doubles as *stop speech*;
  starting any recording barges in and silences playback.
- Escape commits a pending annotation text note, then exits annotate mode; it
  stays the panic button while the agent is acting.

## MCP server — Voice Flow as Codex's interaction layer

`LocalAPIServer` (port 8792) also serves **MCP over Streamable HTTP** at
`http://127.0.0.1:8792/mcp` (`MCPServer` in `swift/MCP.swift`; registered once
via `codex mcp add -s user -t http voice-flow http://127.0.0.1:8792/mcp` —
Settings → Assistant shows connection status and copies that command;
`MCPServer.lastActivity` tracks the most recent client request).
Tool handlers live in `AppDelegate.handleMCPTool` (`App.swift`); they run on
background HTTP threads and hop to main for UI.

**Sessions**: each Codex instance gets an `Mcp-Session-Id` on
initialize (`MCPSessionRegistry` in `MCP.swift`), but **connecting is not
engaging**: a session stays invisible (no picker dot, no ⌃⌥ slot, not
voice-target-eligible) until its first user-facing tool call —
`report_to_user`, `wait_for_message`, or an overlay tool
(`engagingMCPTools` in `App.swift`; `MCPSession.engaged`). First engagement
claims the voice target only when no engaged session holds it — an active
target is never stolen. Sessions name themselves via `set_session_name`
(silent, no UI; server instructions + a one-time nudge on the first
*engaging* tool result push Codex to call it; unnamed sessions show as
"Codex #N"). `DELETE /mcp` closes one; sessions silent for 2 h are pruned
as ghosts (a live one self-heals — its next request is re-adopted by
`touch()`). **Unread messages outlive everything**: a session that ends or
expires with unseen pushes stays in the picker as a readable ghost entry
(label derived from its newest push), and stacks persist in `pushes.json`
across app restarts; a 60 s sweep clears only read residue of dead sessions
and repaints the number dot / unread ring. Capture hotkeys feed only the
**visibly open conversation** (`ChatPanel.conversationFocus`, or the grown
pill's concrete push session); `AppDelegate.targetSessionId`, changed via
`setTargetSession`, switchable with **⌃⌥1–6** or the menu bar's "Voice
Goes To" submenu, does not route a capture by itself. The submenu lists the
same `pickerSessions()` order/numbering. Switching grows the pill into the session's
push stack (or the one-line picker when it has none); the middle dot
carries the active session's number; re-selecting the current session
while its stack shows reads it aloud (`double_select_speak`). The current
FLORA conversation joins this projection through `assistant:<slug>` without
entering `MCPSessionRegistry`, `sessionPushes`, the MCP inbox, or overlay
ownership; its transcript and unread cursor stay in `AssistantHistoryStore`.
**Overlays
are session-scoped** (`"session"` field, stamped by the tools): only the
active session's elements render; a background session's overlay triggers
a transient note instead of drawing over the user. The inbox is per-session
(`InboxMessage.session`; nil = any session may drain it), and ask bubbles
are labeled with the asking session when several are connected. 14 tools
in three groups (plus `set_session_name` above):

**Talking with the user**
- `report_to_user` — the ONE messaging tool: `summary` + `details`
  (schema-required context), optional `question` which **blocks** until the
  human answers (`PendingInteraction` semaphore; the unified capture delivery
  path and `sendTypedMessage` route the answer to it; timeout up
  to 4 h). Reply modes: Dictate, Dictate + snapshot, typing, or a whole
  continuous-capture demonstration.
- `check_messages` / `wait_for_message` — the async path. A contextual capture
  routed to a session is delivered live to a listening target (parked in `wait_for_message`),
  otherwise **queued in the target session's `MessageInbox`**
  (`swift/Inbox.swift`, `inbox.json`) and surfaced by the piggyback nudge
  on its next *voice-flow* call. The reply channel agents are steered to —
  mid-task or after their turn ends — is backgrounding `vf listen --attach
  <session-id>` (the `communicate-with-user` skill's script): the task
  completes with the user's words and re-invokes the agent.
- `get_latest_capture` / `list_captures` / `get_recent_dictations`,
  `take_screenshot` (fixed ≤1440-px geometry via `CaptureStore.shotGeometry`,
  includes the cursor position in image space).

**Showing the user — file-backed overlays (`swift/Overlay.swift`)**
Every on-screen element is a live JSON file in
`~/.config/voice-flow/overlays/` (schema written to `_schema.md` there).
`OverlayManager` polls at 0.5 s and re-renders on any change, so MCP tools
and direct file edits are equivalent; deleting a file (or the panel's ✕)
removes the element. Types: `guide` (step list, done/active/pending),
`panel` (heading/text/code/bullets blocks), `annotations` (circle, arrow,
label, rect, line — click-through, coordinates in take_screenshot pixels).
Tools: `show_guide` / `update_guide` / `show_panel` / `annotate_screen` /
`clear_annotations` / `remove_overlay` / `list_overlays`.

**Voice** is on demand only: the user plays any agent message aloud by
re-selecting the session or via the speaker icon (there is no agent-side
auto-play tool; `speak` was folded into `report_to_user`).

## Capture bundles (`~/.config/voice-flow/captures/<id>/`)

A continuous capture writes every deduped frame live via `CaptureStore`
(`swift/Capture.swift`): `frames/frame-NN-tXXXs.jpg`, then `transcript.md` +
`meta.json` when transcription lands (bundles pruned to 40; ad-hoc shots in
`captures/shots/`). On continuous-capture end the bundle follows its frozen
contextual route; the menu bar keeps the manual **Copy Capture Prompt**
fallback. Codex can also pull bundles through the MCP tools.

## Workflow watcher (`~/.config/voice-flow/watcher/`)

The ambient watcher (menu bar → "Workflow Watcher" submenu — live frame count,
toggle, Run Review Now, open latest review / data folder — pill right-click, or
the Settings → Watcher tab: interval / idle pause / retention sliders + review
actions; `WorkflowWatcher` in `swift/Watcher.swift`, `watcher_*` settings; a
faint amber pill ring shows while it records) ticks every 5 s (configurable)
while the user is active (input within the last 90 s, screen unlocked): one
metadata line — frontmost app, window title, browser-tab URL
(per-browser AppleScript; needs the one-time Automation grant) — appended to
`<yyyy-mm-dd>/activity.jsonl`, plus a deduped ≤1568-px screenshot, plus — when
a body camera is picked in Settings → Watcher (`watcher_camera_id`,
`CameraGrabber`) — a motion-deduped ≤960-px `cam-*.jpg` of the user. Day
folders are pruned to the newest 30. A LaunchAgent
(`~/Library/LaunchAgents/com.voiceflow.watcher-analyze.plist`, 21:37 nightly)
runs headless Codex against `watcher/ANALYZE.md`, which aggregates the
log by script (never raw into context), maintains the observations ledger
(`ledger.md`, patterns suggested only after 3+ sightings on 2+ days), writes
`reviews/<day>.md`, and surfaces suggestions via the MCP overlay tools. The
user-level `/screenwatch` skill (`~/.claude/skills/screenwatch/` and
`~/.codex/skills/screenwatch/`) is the on-demand analyze/optimize/status
version. The out-of-app pieces — the
LaunchAgent plist, `ANALYZE.md` + its `.claude/settings.json` tool grants, and
the `/screenwatch` skill — are vendored in the repo's `watcher/` directory and
deployed by `install.sh` (see `watcher/README.md`); edit them there, the
deployed copies are build outputs.

## Persistent data (`~/.config/voice-flow/`)

- `settings.json` — `UserSettings` (hotkeys, TTS voice/speed/instructions, agent model, …).
- `dictations.json` — dictation history (`[HistoryEntry]`, JSON), written by
  `DictationsView` on each new dictation (render cap 60, store cap 200). Survives restarts.
- `messages.json` — every agent push (`[AgentMessageEntry]`: time, session,
  text, isAsk), written by `MessagesView` (same caps). The Messages tab's store.
- `assistant-sessions.json` — versioned in-app Assistant conversations: ordered
  user/assistant/note messages, per-runtime bindings/cursors, preferred runtime,
  titles, and turn state. Restored on launch so Assistant sessions remain selectable/resumable;
  the first upgraded launch imports only Codex rollouts carrying Voice Flow's
  explicit Assistant preamble and removes empty scaffold drafts.
- `pushes.json` — the live per-session push stacks (`sessionPushes`), saved on
  every mutation so unread messages survive app restarts as ghost entries.
- `inbox.json` — queued contextual-capture messages for Codex (`MessageInbox`).
- `overlays/*.json` — live on-screen elements (`OverlayManager`); `_schema.md` documents the format.
- `watcher/` — ambient workflow log (`WorkflowWatcher`): per-day `activity.jsonl` + deduped frames, plus `ANALYZE.md` / `ledger.md` / `reviews/` for the nightly review.
- `agent-jobs.sqlite` — durable agent jobs, runs, leases, retries, costs, and trigger dedupe.
- `agent-security.jsonl` — redacted permission/security decisions for private agent tools.
- `runtime/opencode/<trust-profile>/` — generated private config/XDG roots and bounded runtime logs; never provider credentials.
- `app.log` — `vflog` output.
- OpenAI / agent API keys live in the **Keychain** (`KeychainStore`), not on disk.

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

## Conventions

- **Minimal, surgical edits.** This is a personal daily-use app; scope changes
  tightly and avoid touching unrelated subsystems (dictation capture, the agent
  loop, hotkeys, permissions).
- All UI is dark (`Theme` palette). Prefer the existing `Theme.*` colors and
  reuse `HoverCardView` / `FlippedView` for lists.
- `TTSController`, `TTSRequest`, voices/presets are the single TTS engine — drive
  it through `ChatPanel`'s TTS passthroughs, not by duplicating controls.
