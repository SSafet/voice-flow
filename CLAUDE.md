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

## Persistent data (`~/.config/voice-flow/`)

- `settings.json` — `UserSettings` (hotkeys, TTS voice/speed/instructions, agent model, …).
- `dictations.json` — dictation history (`[HistoryEntry]`, JSON), written by
  `DictationsView` on each new dictation (render cap 60, store cap 200). Survives restarts.
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
| `Agent.swift` | `AgentSession`, `ComputerControl` | LLM loop that reasons over screenshots and issues screen-control tool calls. |
| `Annotation.swift` | `AnnotationOverlay` | Draw-on-screen overlay. |
| `Settings.swift` | `SettingsStore`, `SettingsWindowController`, `PermissionsWindowController`, `KeyRecorderView` | SwiftUI settings & permissions windows. |
| `ScreenCapture.swift` | `ScreenCapture`, `CaptureScheduler`, `ImageUtils` | ScreenCaptureKit screenshots for the agent. |
| `TTS.swift` | `TTSController`, `TTSRequest`, `TTSStatusSnapshot`, `LocalAPIServer`, `OpenAITTSVoices` | Text-to-speech engine + a localhost HTTP control API. |

## Conventions

- **Minimal, surgical edits.** This is a personal daily-use app; scope changes
  tightly and avoid touching unrelated subsystems (dictation capture, the agent
  loop, hotkeys, permissions).
- All UI is dark (`Theme` palette). Prefer the existing `Theme.*` colors and
  reuse `HoverCardView` / `FlippedView` for lists.
- `TTSController`, `TTSRequest`, voices/presets are the single TTS engine — drive
  it through `ChatPanel`'s TTS passthroughs, not by duplicating controls.
