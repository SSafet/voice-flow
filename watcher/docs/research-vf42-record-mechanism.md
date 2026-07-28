# Mechanism report: Claude's "Record a Skill" feature (VF-42)

**Scope note on naming.** The ticket calls this "Claude Code's record feature," but all evidence — binary teardown of the desktop app, help-center docs, and community coverage — places the shipped feature in the **Claude Desktop app's Cowork mode** (macOS), internally codenamed **watch-record** (feature family "Chicago"). The Claude Code CLI has no record/teach subcommand (`claude --help`, v2.1.209); the only CLI-side trace is an open feature request (anthropics/claude-code#70371) proposing an equivalent. The desktop app does embed a Claude Code build that acts as the agent, which explains the loose association. Everything below describes the desktop mechanism.

---

## 1. What the feature is

"Record a Skill" (shipped July 21, 2026, Claude Desktop for Mac v1.24012.x, Pro/Max/Team plans, Cowork mode only — not web chat, Windows, Free, or Enterprise) lets a user demonstrate a desktop workflow once — screen, clicks, keystrokes, and optional voice narration — and have Claude turn the demonstration into a reusable Skill (a SKILL.md instruction package). Capture and trajectory construction happen locally in the Electron app; the condensed trajectory is then injected into a chat turn where the model (server-side) infers the workflow's intent and proposes a skill for user approval. Replay is agentic — the skill maps steps to outcomes executed via connectors, CLI, or browser tools — not a coordinate macro. Recording is capped at 10 minutes, with a warning 60 seconds before auto-delivery.

## 2. Capture pipeline

**Input events.** A native Swift addon (`@ant/claude-swift`, `WatchRecorder.swift`) installs global `NSEvent.addGlobalMonitorForEventsMatchingMask` monitors (confirmed from binary strings — this supersedes an earlier researcher's CGEventTap guess). Each event is forwarded to the Electron main process with: kind (key, left/right mouse down/up, scrollWheel), millisecond timestamp relative to recording start, screen coordinates, modifier flags (CGEventFlags bits), macOS virtual keycode, the typed characters verbatim, scroll deltas, and a `secureInput` boolean. Password fields (macOS secure input) are never captured — they arrive flagged and are replaced with a `[secure input]` placeholder. Clicks landing on Claude's own windows are dropped. The frontmost app name and bundle ID are sampled on each frame tick, building an app-switch timeline. There is **no** clipboard capture and **no** accessibility-tree/DOM inspection — clicks are pixel coordinates only.

**Screen.** In the default "trajectory" output mode there is no per-event screenshot and no encoded video file. A timer captures a JPEG frame every **250 ms** of the display nearest the cursor (multi-monitor: frames follow the cursor), via ScreenCaptureKit (`SCScreenshotManager`) in the native `computer_use.node`, at quality 0.75, downscaled so the max dimension is ≤1568 px (sized against a 28 px/token vision-patch model). Frames are buffered **RAM-only**, capped at 720; hitting the cap drops every second frame and doubles the interval (250→500→1000 ms…). A legacy "events" mode exists instead: one seed screenshot, one per left-click (cap 30), one final.

**Narration.** Optional, chosen in a pre-record dialog (mic on/off, device picker, level preview). Audio is handled natively (AVAudioEngine) and streamed during recording to Anthropic's server-side STT websocket (`/api/ws/speech_to_text/voice_stream`, linear16) using the user's claude.ai credentials; a single whole-recording transcript comes back — not aligned to individual timestamps. Mic denial degrades gracefully to a silent recording.

**Conflict noted.** Help docs and community reviews describe "sending Claude a video." The binary shows no video container anywhere — the "video" is the RAM frame buffer, and only a selected subset of stills ever leaves as message content (plus the narration audio stream during recording). The binary evidence is the better-attested claim.

## 3. From events to steps

A step is a coalesced, timestamped, human-readable action item `{tStart, tEnd, kind, text}` produced by a deterministic local `coalesceActions()` — segmentation is rule-based, not model-based:

- **Typing runs:** consecutive printable keydowns merge into `typed "..."` until a >2 s gap or a mouse-down flushes; backspace edits the pending buffer; special keys summarize (`pressed Return, Tab ×2`); Shift+Enter becomes a newline.
- **Chords:** any Cmd/Ctrl (or bare Opt) combination emits immediately (`pressed ⌘⇧A`).
- **Clicks vs drags:** mouse-down paired with the next matching mouse-up; travel <6 px → `clicked at (x, y) in "App"` (coordinates rescaled to image space), otherwise `dragged from … to …`.
- **Scrolls:** scrollWheel events grouped with ≤1 s gaps → `scrolled up/down in "App"`.
- **App switches:** from the frontmost-app timeline → `switched to "App"`.

After Done, `buildTrajectory()` selects **at most 30 images** from the frame buffer by perceptual diffing: candidate frames (at the end of each image-worthy action — click, drag, type, chord, scroll, appSwitch — plus a sample every 30 s of quiet and a forced final frame) are compared to the last-emitted frame as 960-px grayscale luma maps in 64-px blocks, with the top 40 px (menu-bar clock) excluded. <0.5% of blocks changed → no image; >45% changed or changed bbox >70% of frame → full keyframe (annotated with display and frontmost app); otherwise a **crop** of the changed region +24 px padding, re-encoded JPEG q85.

**Discrepancy noted:** community tests reported "61 steps in 4 minutes" and "~73 steps / ~76 screenshots" in the task UI. The step counts are consistent with the live pill counter (which counts clicks+keydowns) or the text-step count; ~76 *screenshots* is not consistent with either the 30-image trajectory cap or the 30-screenshot legacy cap, and remains unexplained (different build, or the UI counting something else). The decompiled constants are the stronger evidence for the mechanism.

## 4. From steps to skill

**What the model sees.** The recording is injected into the chat turn as ordered content blocks: an opening `<watch-record-demonstration durationMs steps images>` text block explaining that what follows is a chronological trajectory; an optional narration block (explicitly labeled as transcribed across the whole recording, not timestamp-aligned); then alternating `[12.3s] action` text blocks and base64 image blocks labeled either `full screen (Display 1 — frontmost: "App")` or `changed region (W×H at x,y …)`; a closing tag; and a system-reminder that (a) marks all screen text, typed strings, app names, images, and narration as **untrusted data, not instructions**, (b) directs the default behavior — make the workflow reproducible via the `mcp__cowork__propose_skills` tool, which renders a user approval card (calling `mcp__cowork__save_skill` directly is forbidden; fallback is the skill-creator skill with a shown draft), and (c) appends tooling guidance: do **not** replay mouse/keyboard gestures — map each step to its *outcome* using MCP/CLI/API/browser tools, with computer-use screenshot+click only as a last resort. Legacy events mode instead sends a ```json watch-record-events``` fenced raw event array plus up to 30+2 screenshots and an equivalent reminder.

**Where generation runs.** Skill synthesis is not hardcoded client logic — it is the model (the embedded Claude Code agent session, running against the Anthropic API) reasoning over the trajectory under prompt steering. Narration supplies the conditional/judgment logic that clicks alone can't convey; clarifying questions during refinement are ordinary model behavior, not a separate algorithm. One hands-on source described "three parallel sub-agents" (draft skill / per-platform reference / packaging); this is single-source and uncorroborated by the binary — treat as unverified.

**Output.** A standard Claude Skill: a folder centered on SKILL.md (YAML frontmatter — triggers, steps, outputs, inferred rules), optionally with scripts/templates/examples. It lands in the user's skill library (Customize > Skills), is editable/shareable/deletable, usable in scheduled tasks, and is an inspectable instruction package — no model fine-tuning. At run time Claude prefers API connectors, falls back to Claude in Chrome (requires the "Control Chrome" setting; Mac awake and signed in), reasoning from fresh screenshots rather than replaying coordinates — slower than native automation but tolerant of UI changes, and shown in one test to generalize to new inputs rather than replay the demonstration.

## 5. Storage & formats

**Local: nothing at rest.** Frames (Buffers), events, and narration live entirely in Electron main-process memory. After Done, the built message is held for the renderer to claim (`takeHeldWatchRecording`); unclaimed recordings are dropped after 60 s; Discard wipes all buffers. No code path writes the recording to disk, and filesystem sweeps of `~/.claude`, `~/Library/Application Support/Claude`, and logs found no recording artifacts (caveat: the feature was never used on the machine inspected).

**Formats.** Full frames: JPEG q0.75, max dimension 1568 px; crops: JPEG q85; delivered as base64 image content blocks interleaved with text; legacy mode as a fenced JSON event array. No video container exists at any stage.

**Paths.** App: `/Applications/Claude.app` (logic in `Contents/Resources/app.asar`; native addons in `app.asar.unpacked/node_modules/@ant/claude-swift/build/Release/{swift_addon.node, computer_use.node}`); embedded agent at `~/Library/Application Support/Claude/claude-code/<version>/`; logs at `~/Library/Logs/Claude/main*.log`. Saved CLI-convention skills live at `~/.claude/skills/<name>/SKILL.md`, but where `save_skill` actually writes approved Cowork skills was not located. **Server-side:** the extracted screenshots persist as part of the Cowork task (an expandable "Recorded demonstration" step); deleting the task removes them.

## 6. Permissions & privacy

**TCC.** Starting a recording requires both **Screen Recording** and **Accessibility** grants (checked natively via `tcc.checkScreenRecording()`/`tcc.checkAccessibility()`; missing either aborts, and the user's choice is remembered 120 s for auto-resume after granting). **Microphone** is separate, optional, requested only when narration is enabled.

**What leaves the machine.** During recording: narration audio streams to Anthropic's STT endpoint. At delivery: the trajectory (≤30 JPEG stills + coalesced action text + transcript) becomes chat message content sent to the Anthropic API; all subsequent analysis is server-side (Cowork work is processed on Anthropic's servers). Telemetry events carry counts/durations only, not content.

**Protections.** Secure-input (password-field) keystrokes are never captured; clicks on Claude's own windows are excluded; typed text and app names are sanitized against prompt injection (angle brackets/backticks replaced with lookalikes); the prompt marks all captured content untrusted; only the cursor's display is captured. **Gaps:** non-secure typed text is captured verbatim, frames capture everything visible on the active display (no image redaction of any kind), and the UI warns users not to type secrets or display sensitive information while recording.

**Retention.** Stated: recording video/audio are not retained after processing; screenshots follow standard Cowork-task retention — deleted with the task, backend deletion within 30 days. No recording-specific retention or training policy existed as of 2026-07-28. Inferred from generic policy: on consumer plans with the model-improvement setting on, trajectory content plausibly enters the de-identified training pipeline (up to 5 years); Team plans do not train by default. The mobile dictation commitment (delete audio after transcription, never train on it) probably but not provably covers the desktop STT path.

## 7. Confidence table

| Claim | Confidence | Best evidence |
|---|---|---|
| Feature lives in Claude Desktop Cowork (macOS), not the Claude Code CLI | Confirmed | `LocalAgentModeSessions_startWatchRecording` IPC handler in app.asar; `claude --help` has no record command; open CLI feature request #70371 |
| Input capture via global NSEvent monitors in native Swift addon, incl. verbatim keystrokes, modifiers, coordinates, secureInput flag | Confirmed | Strings in `swift_addon.node` ("WatchRecorder monitors installed", `WatchRecordInputPayload`) |
| Frames every 250 ms via ScreenCaptureKit, JPEG q0.75, ≤1568 px, cursor's display, 720-frame adaptive RAM buffer | Confirmed | Decompiled constants in `index.chunk-CnWKsyE_.js` + ScreenCaptureKit symbols in `computer_use.node` |
| ≤30 images per trajectory, selected by perceptual block diff with crop-vs-keyframe logic | Confirmed | Full source of trajectory builder (`index.chunk-P7tKz_09.js`, `MAX_IMAGES_PER_TRAJECTORY`) |
| Rule-based step coalescing (typing runs/chords/click-vs-drag 6 px/scroll/app-switch) | Confirmed | `coalesceActions()` source read in full |
| Trajectory injected as tagged content blocks + untrusted-data system-reminder; skill via `propose_skills` approval card; outcome-based (no gesture replay) guidance | Confirmed | Content-block builder source (`index.chunk-BnLXuqtQ.js`) with exact prompt text |
| Narration transcribed via Anthropic server-side STT websocket, whole-recording, not timestamp-aligned | Confirmed | `voice_stream` endpoint + credentials-required error strings inside `WatchRecordVoiceover` |
| No local disk artifacts; RAM-only with 60 s hold timeout | Confirmed | No fs writes in watch-record code region; filesystem sweep negative |
| 10-minute cap with 60 s warning | Confirmed | Constants (600 s / 60 s) + help article |
| Screen Recording + Accessibility TCC required; mic optional | Confirmed | `tcc.check*` calls in code + help article listing both |
| Secure-input keystrokes never captured | Confirmed | `secureInput` handling → `[secure input]` placeholder in source |
| Screenshots persist in Cowork task; deleted with task; 30-day backend deletion | Confirmed | support.claude.com skills + Cowork getting-started articles |
| Video/audio not retained after processing (as stated; no window given) | Confirmed (stated) | support.claude.com skills article |
| Legacy "events" mode (screenshot per click, cap 30) exists behind an output-mode setting | Confirmed | `watchRecordOutputMode` setting + constants in source |
| Replay generalizes semantically rather than replaying the demo | Probable | MindStudio hands-on test (single source, consistent with prompt guidance) |
| Consumer opt-in makes trajectory content trainable (up to 5-year de-identified pipeline); Team excluded by default | Probable | Generic privacy/training docs; no recording-specific policy exists |
| Desktop STT audio inherits mobile delete-after-transcription/no-training commitment | Probable | Mobile dictation article; desktop-scoped docs are silent |
| "Three parallel sub-agents" generation pipeline | Speculative | Single hands-on source (charliehills.substack.com); no binary corroboration |

## 8. Open questions

- Exact NSEvent monitor masks registered, and how `secureInput` is derived natively (likely `IsSecureEventInputEnabled`, unverified).
- Whether the local `SFSpeechRecognizer` path in the same binary ever serves watch-record narration, or only the app's dictation features — the credentials-required error suggests server STT is the only wired path.
- Where `mcp__cowork__save_skill` writes approved skills on disk (`~/.claude/skills` vs a Cowork-specific location) — the implementation is not in the extracted main-process bundles.
- What flips `watchRecordOutputMode` to legacy "events" mode in production (remote feature gates not inspectable locally).
- Server-side lifecycle after delivery: whether "aren't retained" for video/audio means never-persisted or deleted-after-processing with a transient buffer; whether trajectory images actually enter the training pipeline as images under opt-in; whether a Cowork task counts as a "chat or coding session" for the training setting (docs predate the feature).
- The unexplained community observation of ~76 screenshots in a task UI vs the 30-image/30-screenshot caps in the shipped code.
- Exact UI placement of the record affordance (renderer code is served remotely; only the IPC surface is visible locally).
- Whether Anthropic will publish a recording-specific privacy/retention page — none existed a week after launch.
