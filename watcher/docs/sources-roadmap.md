# Sources — roadmap, decisions, and what was killed

Companion to `sources-architecture.md`. Produced 2026-07-28 by folding the
VF-42 research (`research-vf42-record-mechanism.md`) into the watcher, then
running the result through adversarial review against the real Swift code and
the real 18-day archive. 33 of 34 serious objections to the first draft were
upheld — most of them against my own proposals. Numbers below are measured on
this machine's archive, not estimated.

Ordering is by (blind-spot yield + value) ÷ effort. Nothing here needs a macOS
permission Voice Flow does not already hold.

---

## Wave 0 — fix what is already broken

Three live defects, found while checking whether the new ideas were affordable.
None needs a decision.

1. **Frame compression is a Retina no-op.** `ImageUtils.compress` computes the
   new size in *points* and renders through `lockFocus`, whose backing store is
   allocated at 2×. `maxDimension: 1568` therefore writes 3136 px JPEGs —
   verified on 1,652 of 1,654 frames on 07-27, and on every day folder.
   Delegating to the existing `resizeExact` (an explicit CGContext at exact
   pixel size, ~4 lines) takes stored frames from 369 KB to 103 KB, the 30-day
   archive from **8.3 GB to ~2.3 GB**, and removes a ~93 ms CPU burst that
   fires 780+ times a day. Zero information loss — the vision path downsamples
   those pixels away anyway. Ship it first so nothing else gets credited with
   the savings.
2. **Half-resolution capture.** `config.width = Int(display.width / 2)` — the
   external display has been captured at half its real geometry on six archived
   days. `Int(display.width)` is the minimal correct fix (multiplying by
   `scale` instead would quadruple the retained buffer for no change to the
   stored frame).
3. **Permanent-stall latch.** `captureScreen()` has no timeout, `browserURL`'s
   kill timer only sends `SIGTERM`, and `stop()` never resets `capturing` — so
   one hung capture stops the watcher for good, silently. Add a watchdog that
   force-clears the latch and logs `watcher_stall` after 20 s in flight.

Alongside: **self-exclusion.** The watcher currently photographs its own panel
and reply bubbles, so the nightly agent reads its own prior output back as
observed activity. Exclude own windows from the capture filter, and (whenever
input is read) drop events whose source PID is our own — the same filter
already exists elsewhere in the codebase.

---

## Wave 1 — the nightly agent's blast radius

The review verified, by execution, that a non-allowlisted command runs under
today's setup: the LaunchAgent inherits `defaultMode: auto`, so the allowlist
is not the ceiling. It also verified that `Write`/`Edit` **deny** rules do not
work in Claude Code 2.1.209 — only `Read` denies do. So containment has to come
from removing grants, not from denying paths.

- Pin `--permission-mode manual` in the plist.
- Replace `Bash(python3:*)` with a first-party `aggregate.py` under
  `Bash(python3 aggregate.py:*)`. Argument denylists are not an option —
  `python3 -` and `python3 /tmp/x.py` defeat them.
- Replace unqualified `Write`/`Edit` with `Write(./**)` / `Edit(./**)`; add
  `Read` denies for `~/.ssh/**`, `**/.env*`, `~/.config/gh/**`, `~/.claude/**`.
- Wrap the LaunchAgent in `sandbox-exec`: file writes confined to the watcher
  directory. This is load-bearing, not belt-and-braces, precisely because the
  deny rules don't work.
- Add the untrusted-data banner and an explicit write-scope paragraph to
  `ANALYZE.md`, the renderer header, and the `SOURCE.md` template. `ANALYZE.md`
  today contains zero occurrences of "untrusted", "injection", or "not
  instructions" across 150 lines — while it actively invites `note-*.md` files
  whose authenticity rests on a filename glob.

---

## Wave 2 — close the blind spot with what we already have

The blind spot is **metadata**, not pixels. The frames already carry session
names, run state and model badges; the ledger diagnosed this correctly. Inside
constant-titled agent apps the watcher under-samples 2.4–4.4×, but it is not
blind — the gap is that 46.9% of logged time says `app: "Claude"` and nothing
else, and the read budget only ever looks at ~3% of the day's frames.

4. **Input counters (zero permission, ~10 lines).** Sample
   `CGEventSource.counterForEventType` per tick for keyDown, clicks,
   right-clicks, scroll, drag and modifiers; write the deltas onto the existing
   line. Verified callable with Accessibility *and* Screen Recording denied.
   Excludes `mouseMoved` (163,322/day of noise). This separates reading a
   streaming reply (no keys, no clicks, low scroll) from writing a prompt (key
   burst) from scrolling a feed (scroll climbing, keys flat) — the
   distraction-vs-work question `ANALYZE.md` asks by name. Best yield per unit
   effort in the whole plan.
5. **`voiceflow.jsonl` run-state stream.** Four stores already sit one
   directory above `watcher/` and have never been read by any review:
   dictations, messages, session names, pushes. Measured overlap: of the 65
   dictations carrying a full timestamp, 45 (69%) happened while Claude or
   ChatGPT was frontmost; extending each as a label over surrounding activity
   covers **20–27% of otherwise-opaque agent minutes** with Safet's own stated
   intent — zero capture cost, zero permission, zero model call, text already
   on disk. Blocking defect to fix first: 135 of 200 dictation records have
   `timestamp: null`, and messages carry no date at all. The ledger has asked
   for this stream on five separate dates; the listener-vs-spinner experiment
   has been blocked on it since 07-19.
6. **Focused-element probe.** One element, two attributes, once per tick, off
   the main thread: focused role and character count — never the value. The
   exact call pattern and the grant already exist in production. A rising char
   count inside a constant-titled window is composing; a non-text role with
   scroll is reading; neither, with a stable changed-bbox, is waiting. This
   delivers most of what a keystroke coalescer would, without capturing a
   single character.
7. **Clipboard `changeCount` and window bounds.** Six lines and one free
   dictionary key. `ANALYZE.md` names "copy-paste shuttles" as a first-class
   inefficiency the watcher currently cannot see at all; paired with click
   counts, a copy in app A followed by a ⌘V chord in app B within 30 s is a
   fully attributed shuttle. Window bounds retire a standing manual judgement
   in the ledger (discounting "the cheap split-screen kind" of churn burst,
   re-litigated by eye three times).

---

## Wave 3 — the architecture itself

8. **`SourceScheduler`, two source classes, budgets, `private/`,
   `capture-policy.json`.** As specified in `sources-architecture.md`. This is
   a registration job, not a rewrite: `WorkflowWatcher` already implements the
   per-source timer, the re-entrancy guard, restart-on-config-change and one
   status row. What it lacks is the watchdog (Wave 0) and scheduler-owned
   retention.
9. **Trajectory renderer, episode-scoped.** `render(day, t_start, t_end,
   max_images)`, at most 2 calls per nightly run at 20 images each. Requires
   episode segmentation as new work in `ANALYZE.md` step 2 (idle gap ≥ 90 s or
   return to a work surface; take the two longest by rank).

---

## Wave 4 — the topical fix, gated on one decision

10. **Block-diff bbox + luma-plane caching + agent-app heartbeat.** Compute a
    150-block luma diff, keep its **bounding box**, and store `chg`,
    `chg_pct`, `idle` on the tick. This is CPU-*negative* (3.25 ms vs 6.33 ms
    per tick) and cuts retained memory 13× — today's diff decodes two 7.72 MB
    TIFFs on the main thread every 5 s. Force a frame when none has been
    written for 15 s while an agent app is frontmost: +238 frames/day,
    +0.74 GB at 30 days against an archive Wave 0 already cut to ~2.3 GB.
    **Do not** port the 0.5% skip rule, the 45% keyframe split, or write-time
    cropping — see "killed" below.
11. **Fixed-ROI crop → cheap vision OCR.** Point the crop at a *fixed* region
    (the agent window's sidebar/header, ~200×600 px, 15–25 KB) rather than the
    changed bbox, on every agent-app entry, and let the v1.1 vision source
    read it into `vision.jsonl` as `{session, state, elapsed, model}`. Per-app
    ROIs live in that source's `SOURCE.md`, so a UI redesign is a config edit.
    This is the **only** candidate that converts `app: "Claude"` into named
    sessions and projects — the ledger's own 07-24 note rules out the run-state
    stream as sufficient, because both a build turn and a shopping-research
    turn just "run". It carries the egress decision, so it ships after Wave 2
    has taken the cheap share of the gap, and after a **dry-run egress day**
    that writes the exact outbound payload to `<day>/vision-egress/` locally
    and sends nothing.

---

## Decided 2026-07-28 — and what shipped

Safet took four of the eight decisions below, two of them **against** my
recommendation. Recorded here so they are not re-litigated:

1. **Keystrokes: verbatim, not shape-only.** Overrides my recommendation. The
   coalescer is core, not deferred — counters are the filler *between* actions,
   the coalesced actions are the substance. Password protection is by three
   independent layers (secure input per keystroke, focused-element role, bundle
   denylist), not by refusing to record.
2. **No image cap.** The archive is always-on and exists to be looked at; if
   more frames are needed, take more. The end state is a cheap model reading a
   whole day to give the expensive one context. The 45-image budget is dropped.
3. **No panic / discard control.** Not applicable — this is continuous
   observation, not a bounded recording session with a delivery moment.
4. **Camera** stays out of the plan; its budget line in `ANALYZE.md` is softened
   rather than deleted.

The implementation was then reviewed adversarially against itself. Fifteen real
defects came back and were fixed, four of them blockers: an accessibility
timeout set on the system-wide element (documented to apply **process-wide**,
which would have silently shortened dictation's own accessibility calls);
own-window exclusion applied to the shared capture path (which would have
returned blank annotation and agent screenshots); a password guard that failed
**open** on any probe timeout; and terminal password prompts, which defeat every
layer — `ssh`/`sudo` prompts are drawn by the far end, so nothing asserts secure
input and the password looks exactly like a command. Terminals are now
shape-only. The diff thresholds were also recalibrated after measurement showed
the originals missed ordinary selection and hover changes in **both** light and
dark themes.

Shipped the same day (waves 0–3 below, plus the coalescer from wave 4):
the three capture defects, self-exclusion from own frames, `DayBus` +
`SourceScheduler` + `sources-status.json`, the `desktop` source with its
enriched tick, the input coalescer with `actions.jsonl`, block-diff with the
changed rectangle, the agent-app frame floor, `CONSUMING.md`, and
`sources/desktop/SOURCE.md` (deployed to `~/.config/voice-flow/sources/`,
outside the nightly agent's write scope). Still open: the `voiceflow` run-state stream, the
trajectory renderer, `poll` sources, `vision`, and VF-46's agent hardening.

## Decisions that are Safet's

1. **Keystroke content — shape-only, or verbatim inside an agent-app
   allowlist?** *Recommendation: shape-only, and revisit only if items 4, 5 and
   6 have run for 14 days and demonstrably fail.* The volume argument for
   shape-only is wrong (8,244 keyDown/day ≈ 8 KB/day, negligible). Rest it on
   the asset instead: a 30-day grep-able plaintext record of everything typed,
   read nightly by an autonomous agent. The allowlist would be scope reduction,
   not safety — the ledger's own `consumer-research-in-agent` entry shows those
   exact apps carry shopping threads and personal browsing, and they are
   Electron shells hosting OAuth flows. Note the cost is *not* a new permission
   prompt: Accessibility is already held and a live event tap already runs. The
   cost is repurposing a held grant, which is a consent question.
2. **Egress — no new egress, or add the OpenRouter vision source?**
   *Recommendation: add it, but only after the dry-run day is reviewed, with
   one named provider and model, `data_collection: "deny"`, never the
   auto-router, query strings stripped, a messaging-app exclusion list, and
   camera never-sent.* Correct the premise while deciding: egress today is not
   zero — the 21:37 LaunchAgent already sends 10–30 keyframes plus titles and
   URLs to Anthropic under your own account. The delta is volume and provider,
   not first contact. The genuine third-party exposure is other people's
   messages and faces in frames, already live at 365–1,654 frames/day, and
   unaffected by the keystroke question. Also: the day-job framing in
   `ANALYZE.md` is stale — the day job is on a different laptop.
3. **Nightly `Bash` grant — keep, scope, or drop?** *Recommendation: scope it
   to a first-party `aggregate.py` now, move to an MCP tool later.* Pin
   `--permission-mode manual` regardless.
4. **Nightly image budget — keep 10–30, or raise to 45?** *Recommendation:
   raise to 45.* A deliberate ~1.5× vision spend that buys the interleaved
   action+image format in place of ad-hoc frame picking. Denominate in images,
   never tokens — the same count costs 1,568 or 4,784 tokens depending on
   vision tier.
5. **Frames while macOS secure input is active — suppress, or mark?**
   *Recommendation: mark only, with suppression as an off-by-default setting.*
   The flag is session-global with a documented stuck-on pathology (Chrome —
   33.8% of ticks — is a named offender), there is no zero-frame alarm, and
   per TN2150 it only covers keyboard delivery while focus is in a private
   field, so displayed secrets are uncovered anyway. The control that actually
   works is a per-app **and** per-URL frame denylist.
6. **`private/` retention — 3 days or 30?** *Recommendation: 3.* Reviews and
   the ledger are permanent by design and already carry ~270 quoted-evidence
   spans; without the split, one review that quotes evidence turns a 30-day
   stream into a permanent record with no retention control at all.
7. **FileVault.** Currently off. With physical possession, recoveryOS
   `resetpassword` opens the whole archive. *Recommendation: turn it on before
   anything richer than today's capture ships.* Your action, not a code change.
8. **Camera.** Zero of 48,267 activity lines carry a `cam` key across 18 days
   and `watcher_camera_id` is still empty. *Recommendation: drop the "~6 cam
   frames per review" budget line from `ANALYZE.md`* rather than keep budgeting
   image spend for a stream that has never produced a row.

---

## Killed — do not re-propose

Each of these was in the first draft or the research and died against a
measurement.

- **The 0.5%-blocks-changed skip rule.** Arithmetically inert at our geometry:
  a 960×621 map is 150 blocks, so one changed block is 0.667% — already above
  the cut. Verified 0.00% "emit nothing" across three days. Ported literally it
  takes 780 frames/day to ~2,700.
- **Write-time cropping and the "~10× token saving".** Measured 1.3–1.8×
  end-to-end at 5 s cadence; plain downscaling beats it (1568 px = −57% tokens)
  while keeping the whole-screen context the ledger reasons about. The 10×
  figure is a property of a 250 ms cadence. Cropping is also irreversible, and
  frames are cited by filename weeks later. **Compute the bbox, store it, crop
  at read time.**
- **The 45% keyframe split and the 40 px menu-bar constant.** Measured median
  blocks-changed is 28–42%, so 45% lands on a coin flip for the median frame.
  The 40 px is a source-render constant; in our map space it is 13 px and
  removes no block row — express it as a fraction.
- **Interval doubling and candidate dropping under budget pressure.** A RAM
  valve for a RAM-only buffer, applied to a disk-backed log with 353 GiB free.
  Halving the tick rate destroys metrics that are literally `tick_count × 5 s`,
  and budgets breach in the afternoon — i.e. it thins evidence on the
  highest-drift days.
- **Sanitizing `<`, `>`, backticks at capture time.** No sink in the system
  treats them as structure; 342 distinct titles over 7 days contain zero of
  them. It is destructive to permanent evidence spans. Sanitize on read.
- **Skill generation from ambient data.** A 20–60 s same-app episode yields a
  *median of 2 frames*; 53.5% yield ≤2. Three ledger sightings are three
  non-alignable frame sets, not three diffable action sequences. Of 24 ledger
  entries only 2 are procedure-shaped, and for both the fix came from
  target-side API knowledge a reviewer gets by web search, not from the
  recording.
- **A `record` source built from scratch at 250 ms.** A hotkey-driven narrated
  recorder already exists (`CaptureStore`, `CaptureRouting.continuous`, the
  MCP capture tools). The binding limit there is its 1%-of-screen dedup gate,
  not the interval. Upgrade it and route it onto the bus instead.
- **The `stream` source shape in v1.0.** Zero justified consumers — its only
  cited consumer is in-process anyway. Reserve the enum value.
- **Hash-pinning as the security control for external sources.** The pin store
  lives in the same trust domain as the thing it pins. Keep it as an anti-drift
  control; use TCC disclaiming as the boundary.
- **`0700` and provenance headers as controls.** Both govern other UIDs or are
  plaintext in a file the same UID can write. Do the `chmod` as hygiene; don't
  cite it as a control.
- **`Write`/`Edit` deny rules as containment.** Verified ineffective in Claude
  Code 2.1.209 (with a control proving the settings channel was honored).
- **`.metadata_never_index`.** Measured no-op — dot-paths are already excluded
  from the index.
- **Video capture.** The archive is already 5 GB of heavily-deduped stills and
  the consumer is a vision model reading stills.
- **"Coalesced clicks and keystrokes fix the 51%."** They supply none of
  session, project, model or run state — the four things the gap is made of.
  No ledger entry has ever asked for input capture; five have asked for the
  run-state stream.
