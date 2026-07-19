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
```

`install.sh` compiles every file in `swift/` into one binary and prefers a stable
**Developer ID** signing identity so macOS keeps TCC / Keychain grants across
rebuilds (falls back to ad-hoc, which resets permissions each build).

Quick type-check without installing:

```bash
swiftc swift/*.swift -framework Cocoa -framework AVFoundation -framework CoreGraphics \
  -framework ApplicationServices -framework Accelerate -framework Security \
  -framework ScreenCaptureKit -sdk "$(xcrun --show-sdk-path)" -O -suppress-warnings -o /tmp/vf
```

## Primary surface: the ChatPanel

The app's main window is **`ChatPanel`** (`swift/Panel.swift`) — a borderless
floating panel anchored to the little pill (`FloatingIndicator`). It has four
tabs (`ChatTab`):

- **Messages** — the MAIN tab (default on open): persistent history of
  everything agents pushed over MCP (reports / asks), kept in
  `messages.json` so it outlives the sessions and app restarts that produced it.
- **Chat** — converse with the screen agent (type / snap / talk), streamed replies.
- **Dictations** — browsable, copyable history of past dictations.
- **Speech** — paste text and play it through the TTS engine (voice / preset / speed).

The Messages, Dictations and Speech tab contents are the `MessagesView`,
`DictationsView` and `TTSView` classes in `swift/UI.swift`. (They previously lived in a separate
`HistoryWindowController` window, now retired.) The menu-bar "Dictation History"
item and the pill's context menu open the panel on the Dictations tab.

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
while its stack shows reads it aloud (`double_select_speak`). **Overlays
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
- `pushes.json` — the live per-session push stacks (`sessionPushes`), saved on
  every mutation so unread messages survive app restarts as ghost entries.
- `inbox.json` — queued contextual-capture messages for Codex (`MessageInbox`).
- `overlays/*.json` — live on-screen elements (`OverlayManager`); `_schema.md` documents the format.
- `watcher/` — ambient workflow log (`WorkflowWatcher`): per-day `activity.jsonl` + deduped frames, plus `ANALYZE.md` / `ledger.md` / `reviews/` for the nightly review.
- `app.log` — `vflog` output.
- OpenAI / agent API keys live in the **Keychain** (`KeychainStore`), not on disk.

## Module map (`swift/`)

| File | Key types | Responsibility |
|------|-----------|----------------|
| `main.swift` | — | Entry point: `NSApplication` + `AppDelegate`. |
| `App.swift` | `AppDelegate` | Owns & wires everything: components, hotkeys, capability-first capture/delivery, TTS flow, agent session, windows. |
| `CaptureRouting.swift` | `CaptureRun`, `CaptureRouter`, `CaptureCorrelation` | Immutable per-run capability/route state and UUID-based async callback correlation. |
| `CaptureClipboard.swift` | `CaptureClipboard` | One-item plain/HTML/RTFD serialization for copying capture text with embedded image evidence. |
| `WindowPlacement.swift` | `PanelAnchor`, `AnchoredPanelPlacement` | Same-display pill→ChatPanel geometry with visible-frame clamping. |
| `Core.swift` | `UserSettings`, `KeychainStore`, `HotkeyManager`, `AudioRecorder`, `BackendBridge`, `Paster`, `HotkeySpec` | Audio capture, Python STT bridge (subprocess), paste/stream into the frontmost app, settings, global hotkeys. |
| `UI.swift` | `Theme`, `MenuBarManager`, `FloatingIndicator`, `FloatingTranscriptPanel`, `MessagesView`, `DictationsView`, `TTSView`, `HoverCardView`, `KeyRecorderButton` | Menu bar, pill, live transcript overlay, and the Messages/Dictations/Speech tab surfaces. |
| `Panel.swift` | `ChatPanel`, `KeyablePanel`, `ChatTab` | The primary floating panel and its tabs. |
| `ReplyBubble.swift` | `ReplyBubble` | Facade over the pill's grown surface (no window of its own) — forwards messages/asks/streaming to `FloatingIndicator`. |
| `Capture.swift` | `CaptureStore`, `CaptureSummary`, `CaptureBundleMeta` | Capture bundles on disk (session frames + transcript) and ad-hoc screenshot saving. |
| `Inbox.swift` | `MessageInbox`, `InboxMessage` | Persistent queue of contextual-capture messages for Codex (check/wait semantics). |
| `Watcher.swift` | `WorkflowWatcher` | Ambient 5 s screen/app log feeding the nightly workflow review. |
| `Overlay.swift` | `OverlayManager`, `OverlayDoc`, `OverlayShape`, `OverlayBlock` | File-backed on-screen elements: guides, info panels, annotation shapes; watches `overlays/*.json`. |
| `MCP.swift` | `MCPServer` | MCP Streamable-HTTP endpoint + tool catalog for Codex. |
| `Agent.swift` | `AgentSession`, `ComputerControl` | LLM loop that reasons over screenshots and issues screen-control tool calls. |
| `Codex.swift` | `CodexExecBackend` | ChatGPT-subscription assistant turns via `codex exec --json` (OAuth, thread resume, image attach); the default backend, API key is the fallback. |
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
