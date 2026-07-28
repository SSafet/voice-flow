---
name: desktop
class: native
provider: desktop
schedule: every 5s
enabled_by: workflow_watcher_enabled
streams: [activity, actions]
artifacts: [frame-*.jpg, cam-*.jpg]
---

# desktop — what is on the screen, and what was done to it

Screen, apps, input and attention share one cadence, one subject and one cost,
so they are one source rather than four. This file describes what this source
emits and what it means. The rules for *handling* any of it — that it is
untrusted, what may be quoted, how long it is kept — are not here; they are in
[`../../CONSUMING.md`](../../CONSUMING.md) and apply to every source equally.

Two streams. `activity.jsonl` is state: what was on screen every 5 seconds.
`actions.jsonl` is behaviour: what was done, at the moment it was done. Merge
them by `e`. A tick tells you he was in Claude; an action tells you he was
typing a prompt into it.

## activity.jsonl — one line per tick

Every line carries `t` (HH:MM:SS) and `e` (epoch seconds). Ticks stop while the
screen is locked or after `watcher_idle_pause_seconds` without input.

| Field | Meaning |
|---|---|
| `app` | Frontmost application name |
| `title` | Its front window's title, when it has one |
| `url` | Front-tab URL, for known browsers only |
| `win` | That window's `{x,y,w,h}` on the desktop |
| `display`, `geom` | Which display was captured, and the pixel size of the frame **as stored on disk** |
| `input` | Counts since the previous tick: `keys`, `clicks`, `rclicks`, `scroll`, `drag`, `mods` |
| `focus`, `focus_chars` | Role of the focused element and how much text is in it — never the text |
| `chg`, `chg_pct`, `chg_blocks`, `chg_of` | What moved since the **previous tick** |
| `frame` | Screenshot filename, present only when one was written |
| `forced` | The frame was written by the floor below, not by movement |
| `secure` | macOS secure input was active — a password field had focus |
| `cam` | Body-camera frame, when a camera is configured |

Non-tick lines carry a `kind` instead: `watcher_start`, `watcher_stop`,
`pause` (with `reason`: `idle` or `locked`), `resume` (with `after` and
`seconds`). These mark the **edges** of a gap, once each — not once per skipped
tick. A gap in `e` with no `pause` before it means the app was not running.

### Reading the change fields

`chg` is `[x, y, w, h]` — the bounding box of everything that moved since the
last tick, in the coordinate space given by `chg_of` (`[w, h]`, top-left
origin). It is **stored, never applied**: frames are kept whole, because a crop
is irreversible and these files get cited by name weeks later. Crop at read
time from this rectangle when you want to look closely at what changed.

`chg_pct` is the share of 64-pixel blocks that moved. A few percent in a small
box at the bottom of the window is composing; ~50% or more is usually a window
or tab switch.

### When a frame is written

A frame is written when at least `watcher_diff_blocks` blocks differ from the
**last saved frame** — not from the last tick. The question being asked is "is
the picture we already have still a fair likeness?", so slow drift accumulates
until it crosses instead of being averaged away forever.

On top of that there is a floor: while one of `watcher_dense_apps` is frontmost,
a frame is written at least every `watcher_dense_seconds` regardless of what the
pixels look like, and marked `forced`. Those apps — the agent desktop apps,
Notion — hold a constant window title and change too subtly to trip a diff, so
they were previously the least-photographed part of the day despite being where
most of it was spent. The floor is the fix.

## actions.jsonl — one line per thing done

Raw input events are coalesced locally, by rules, into finished actions. No
model ever sees a raw event.

```
{"t":"14:32:07","e":…,"kind":"type","text":"fix the auth bug","chars":16,"ms":3400,"app":"Ghostty"}
{"t":"14:32:11","e":…,"kind":"chord","text":"⌘⇧A","app":"Claude"}
{"t":"14:32:12","e":…,"kind":"click","x":412,"y":890,"display":1,"app":"Claude"}
{"t":"14:32:20","e":…,"kind":"scroll","dir":"down","n":34,"ms":2100,"app":"Google Chrome"}
```

| `kind` | Fields | Rule that produced it |
|---|---|---|
| `type` | `text`, `chars`, `ms` | Consecutive printable keys, closed by 2 s of silence, a mouse press, or a chord. Backspace edits the run in place. |
| `key` | `text`, `n` | A named non-printing key (Return, Tab, Escape, arrows), with a repeat count. |
| `chord` | `text` | Any ⌘ or ⌃ combination, emitted immediately. |
| `click` / `rclick` | `x`, `y`, `display` | A press and release less than 6 px apart. |
| `drag` | `x`, `y`, `x2`, `y2` | A press and release further apart than that. |
| `scroll` | `dir`, `n`, `ms` | Scroll events grouped with gaps under 1 s. |
| `app` | `app` | The frontmost application changed. |

`x` and `y` are **per-mille of the display** — 0–1000 across, 0–1000 down,
top-left origin — not pixels. A fraction is true against any frame however it
was scaled; a pixel coordinate would not be, because frames are stored at a
1568 px long edge while the app's internal screenshot space is capped at 1440.
To point at a frame, multiply by that frame's `geom`. It also reads directly:
`x: 716` is 72% across the screen.

### Keystroke content and the password guard

Typed text is recorded verbatim, because "typed 34 characters" cannot tell a
build turn from a shopping search and the whole point of this stream is intent.

The guard is **fail-closed**: a run is written verbatim only on positive
evidence that the field was ordinary. Anything else sets `"redacted": true` and
the line carries `chars` (and `ms` and `app`) but no `text`. What redacts:

1. **macOS secure input is asserted.** Checked when a run opens and again on
   every keystroke, so tabbing into a password field mid-sentence still
   redacts. Note the real mechanism: while secure input is on, key events stop
   being delivered to monitors at all — so this is a belt-and-braces marker
   rather than the thing doing the work. It is asserted by native secure text
   fields, by Safari, and by apps that opt in. **Most Electron apps do not opt
   in**, which is why layers 2 and 4 exist.
2. **The focused element looks secret.** One accessibility probe when the run
   opens, run off the main thread: a secure-text role or subrole, or a label,
   placeholder or description mentioning password / passcode / secret / PIN.
   The probe returns *redact* on every failure — a timeout, a busy app, no
   focused element, accessibility unavailable.
3. **The app is on the never-verbatim list.** 1Password, Bitwarden, Keychain
   Access, Dashlane, LastPass, KeePassXC, the system SecurityAgent.
4. **The app is a terminal.** Ghostty, Terminal, iTerm2, Warp, Alacritty,
   kitty, WezTerm, Hyper are shape-only, always. A remote `ssh` or `sudo`
   prompt is drawn by the far end: nothing asserts secure input, the focused
   element is just a terminal view, and the password looks exactly like a
   command. No signal separates them, so terminal typing is never recorded
   verbatim. Shell history already holds the commands.
5. **The run is a short string of digits** (≤12 chars, digits/spaces/dashes
   only). One-time codes and card fields auto-advance between boxes, which a
   per-run probe cannot see. A short number carries almost no behavioural
   meaning, so this costs nothing.

**What is not covered.** A password typed into an ordinary-looking text field
in an app that asserts nothing, exposes no accessibility hint, is not a
terminal, and is longer than a digit string, will be recorded. So will anything
secret typed into a normal composer — a token pasted as text, an API key typed
into a chat. Treat `actions.jsonl` as sensitive; `CONSUMING.md` forbids quoting
it into any permanent file, and the day folder expires with retention.

Events Voice Flow synthesizes itself are dropped by process id, so its own
paste and copy keystrokes never appear as the user's.

## Permissions

Nothing here needs a permission Voice Flow did not already hold. Screen
Recording was already granted for capture. Accessibility was already granted
for the hotkeys, and the action monitor is *passive* — unlike the hotkey tap it
cannot consume or alter an event. The `input` counts on the tick line need no
permission at all, which is deliberate: if Accessibility is ever revoked the
action stream stops but the shape of every tick survives, and
`sources-status.json` says `actions_health` instead of failing quietly.

## Knobs

`watcher_interval_seconds` (5) · `watcher_idle_pause_seconds` (90) ·
`watcher_diff_blocks` (2, of ~150 — lower keeps more frames) ·
`watcher_dense_seconds` (15, 0 disables the floor) · `watcher_dense_apps` ·
`watcher_actions_enabled` (true) · `watcher_camera_id` ("" = off).
Retention is not here — it belongs to the bus, because every source writes into
the same day folder.
