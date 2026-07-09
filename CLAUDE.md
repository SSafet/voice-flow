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
floating panel anchored to the little pill (`FloatingIndicator`). It has three
tabs (`ChatTab`):

- **Chat** — converse with the screen agent (type / snap / talk), streamed replies.
- **Dictations** — browsable, copyable history of past dictations.
- **Speech** — paste text and play it through the TTS engine (voice / preset / speed).

The Dictations and Speech tab contents are the `DictationsView` and `TTSView`
classes in `swift/UI.swift`. (They previously lived in a separate
`HistoryWindowController` window, now retired.) The menu-bar "Dictation History"
item and the pill's context menu open the panel on the Dictations tab.

## Hotkey-driven agent flows (no panel required)

The agent is meant to be driven by hotkeys, with the ChatPanel closed:

- **Talk** (hold): voice → transcript → agent prompt, no screenshot.
- **Talk + snap** (hold): same, plus one fresh screenshot (on-screen
  annotations are real windows, so they appear in it).
- **Session** (toggle): records the mic continuously and buffers deduped
  screenshots (`CaptureScheduler`, plus a forced shot whenever annotate mode
  ends); on stop, everything becomes a **capture bundle** on disk
  (`CaptureStore`, see below) offered to Claude Code — the legacy
  send-to-in-app-agent path (`sendSessionBundle`, 8-frame cap) is behind the
  off-by-default `session_send_to_agent` setting. `RecordingPurpose` in
  `App.swift` routes each transcription result (dictation / talk / snapTalk /
  session).
- Replies stream into the **`ReplyBubble`** (`swift/ReplyBubble.swift`), a
  floating bubble above the pill, whenever the ChatPanel is closed; ✕ dismisses.
- With voice replies on (speaker toggle), `AgentReplySpeaker` (`swift/TTS.swift`)
  cuts the streaming reply at sentence boundaries into
  `TTSController.beginLiveSpeech/feedLiveSpeech/endLiveSpeech`, so speech starts
  before the reply finishes. The read-aloud hotkey doubles as *stop speech*;
  starting any recording barges in and silences playback.
- Escape commits a pending annotation text note, then exits annotate mode; it
  stays the panic button while the agent is acting.

## MCP server — Voice Flow as Claude Code's interaction layer

`LocalAPIServer` (port 8792) also serves **MCP over Streamable HTTP** at
`http://127.0.0.1:8792/mcp` (`MCPServer` in `swift/MCP.swift`; registered once
via `claude mcp add -s user -t http voice-flow http://127.0.0.1:8792/mcp` —
Settings → Assistant shows connection status and copies that command;
`MCPServer.lastActivity` tracks the most recent client request).
Tool handlers live in `AppDelegate.handleMCPTool` (`App.swift`); they run on
background HTTP threads and hop to main for UI.

**Sessions**: each Claude Code instance gets an `Mcp-Session-Id` on
initialize (`MCPSessionRegistry` in `MCP.swift`); sessions name themselves
via the `set_session_name` tool (server instructions + a one-time nudge in
the first tool result push Claude to call it; unnamed sessions show as
"Claude #N"). `DELETE /mcp` closes one. Talk hotkeys feed the **target
session** (`AppDelegate.targetSessionId` — newest connection by default,
switchable via the menu bar's "Voice Goes To" submenu). The inbox is
per-session (`InboxMessage.session`; nil = any session may drain it), and
`ask_user` / `notify_user` bubbles are labeled with the asking session when
several are connected. 17 tools in three groups (plus `set_session_name`
above):

**Hearing from the user**
- `ask_user` — **blocks** until the human answers (`PendingInteraction`
  semaphore; `handleResult` / `sendTypedMessage` / `finishSession` route the
  answer to it). Reply modes: talk hotkey, snap-talk (+screenshot), typing,
  or a whole demonstration session.
- `notify_user` / `check_messages` / `wait_for_message` — the async path.
  Talk hotkeys queue into `MessageInbox` (`swift/Inbox.swift`, persisted at
  `inbox.json`) **by default** — the in-app agent only receives them when
  `talk_send_to_agent` is on. `wait_for_message` parks until the user talks
  ("listening mode").
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

**Voice**: `speak` — TTS through the shared engine.

## Capture bundles (`~/.config/voice-flow/captures/<id>/`)

A session writes every deduped frame live via `CaptureStore`
(`swift/Capture.swift`): `frames/frame-NN-tXXXs.jpg`, then `transcript.md` +
`meta.json` when transcription lands (bundles pruned to 40; ad-hoc shots in
`captures/shots/`). On session end the bubble offers **Copy prompt for
Claude**; Claude Code can also pull bundles through the MCP tools.

## Workflow watcher (`~/.config/voice-flow/watcher/`)

The ambient watcher (menu bar → "Workflow Watcher" submenu — live frame count,
toggle, Run Review Now, open latest review / data folder — or Settings → Assistant;
`WorkflowWatcher` in `swift/Watcher.swift`, `workflow_watcher_enabled` setting)
ticks every 5 s while the user is active (input within the last 90 s, screen
unlocked): one metadata line — frontmost app, window title, browser-tab URL
(per-browser AppleScript; needs the one-time Automation grant) — appended to
`<yyyy-mm-dd>/activity.jsonl`, plus a deduped ≤1568-px screenshot. Day folders
are pruned to the newest 30. A LaunchAgent
(`~/Library/LaunchAgents/com.voiceflow.watcher-analyze.plist`, 21:37 nightly)
runs headless Claude Code against `watcher/ANALYZE.md`, which aggregates the
log by script (never raw into context), maintains the observations ledger
(`ledger.md`, patterns suggested only after 3+ sightings on 2+ days), writes
`reviews/<day>.md`, and surfaces suggestions via the MCP overlay tools. The
user-level `/screenwatch` skill (`~/.claude/skills/screenwatch/`) is the
on-demand analyze/optimize/status version.

## Persistent data (`~/.config/voice-flow/`)

- `settings.json` — `UserSettings` (hotkeys, TTS voice/speed/instructions, agent model, …).
- `dictations.json` — dictation history (`[HistoryEntry]`, JSON), written by
  `DictationsView` on each new dictation (render cap 60, store cap 200). Survives restarts.
- `inbox.json` — queued talk-hotkey messages for Claude (`MessageInbox`).
- `overlays/*.json` — live on-screen elements (`OverlayManager`); `_schema.md` documents the format.
- `watcher/` — ambient workflow log (`WorkflowWatcher`): per-day `activity.jsonl` + deduped frames, plus `ANALYZE.md` / `ledger.md` / `reviews/` for the nightly review.
- `app.log` — `vflog` output.
- OpenAI / agent API keys live in the **Keychain** (`KeychainStore`), not on disk.

## Module map (`swift/`)

| File | Key types | Responsibility |
|------|-----------|----------------|
| `main.swift` | — | Entry point: `NSApplication` + `AppDelegate`. |
| `App.swift` | `AppDelegate` | Owns & wires everything: components, hotkeys, dictation flow (`handleResult`), TTS flow, agent session, windows. |
| `Core.swift` | `UserSettings`, `KeychainStore`, `HotkeyManager`, `AudioRecorder`, `BackendBridge`, `Paster`, `HotkeySpec` | Audio capture, Python STT bridge (subprocess), paste/stream into the frontmost app, settings, global hotkeys. |
| `UI.swift` | `Theme`, `MenuBarManager`, `FloatingIndicator`, `FloatingTranscriptPanel`, `DictationsView`, `TTSView`, `HoverCardView`, `KeyRecorderButton` | Menu bar, pill, live transcript overlay, and the Dictations/Speech tab surfaces. |
| `Panel.swift` | `ChatPanel`, `KeyablePanel`, `ChatTab` | The primary floating panel and its tabs. |
| `ReplyBubble.swift` | `ReplyBubble` | Floating streamed-reply bubble (also shows Claude's `ask_user` prompts + capture-saved notes with an action button). |
| `Capture.swift` | `CaptureStore`, `CaptureSummary`, `CaptureBundleMeta` | Capture bundles on disk (session frames + transcript) and ad-hoc screenshot saving. |
| `Inbox.swift` | `MessageInbox`, `InboxMessage` | Persistent queue of talk-hotkey messages for Claude (check/wait semantics). |
| `Watcher.swift` | `WorkflowWatcher` | Ambient 5 s screen/app log feeding the nightly workflow review. |
| `Overlay.swift` | `OverlayManager`, `OverlayDoc`, `OverlayShape`, `OverlayBlock` | File-backed on-screen elements: guides, info panels, annotation shapes; watches `overlays/*.json`. |
| `MCP.swift` | `MCPServer` | MCP Streamable-HTTP endpoint + tool catalog for Claude Code. |
| `Agent.swift` | `AgentSession`, `ComputerControl` | LLM loop that reasons over screenshots and issues screen-control tool calls. |
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
