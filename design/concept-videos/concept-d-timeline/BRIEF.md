# Concept D — "Timeline" (paper)

**Thesis line (title card):** "Your day, and every agent in it."

**Character:** light, printed, calm — warm paper and ink like iA Writer or Things, with
one red accent for "live". The organising idea is **time**: the control center is a day
timeline of every agent run, captures are film strips, schedules are marks on a week.
The signature object is a small **paper bookmark tab** stuck to the right edge of the
screen; everything slides out of the edge like a slip of paper pulled from a book.
Hold `fn` to talk.

Read `shared/storyboard.md` first — especially **Space budget** (hard) and the lessons.

## Palette & material

- Paper `#FBF8F1`, raised paper `#FFFDF8`, ink `#1C1A17`, secondary ink `#57524A`
  (≥ 7:1 on paper), tertiary `#736D63` (≥ 4.5:1), hairlines `rgba(28,26,23,.14)`.
- Accent **red `#D6442C`** = live (listening, the spoken word, recording). FLORA = ink
  blue `#2E56C9`. Needs you = amber ink `#B26A00`; failed = `#C0392B`; running = green
  ink `#2F7D4F`; done = `#8A8479`.
- Paper surfaces sit over light apps, so they are **opaque** with a crisp edge: 1 px
  `rgba(28,26,23,.16)` border + shadow `0 1px 0 rgba(0,0,0,.05), 0 10px 28px rgba(0,0,0,.16)`.
  A faint paper grain (SVG noise at 3–4% opacity) is welcome; no gradients, no glow.
- `system-ui` (SF Pro) for UI; **Menlo/SF Mono** for times, the payload receipt and labels.

## The signature object — the bookmark

- **Rest:** a paper tab flush against the **right screen edge**, vertically at ~62% of
  the screen height: **26 × 78 px**, square right side (it goes off-screen), 6 px left
  corners, paper + border + small shadow. Three **vertical** ink dots (4 px, 8 px apart)
  on it. **Unread:** the middle dot is amber with a thin ring.
- **Listening:** the tab slides out leftward into a slip (below); its dots turn red and
  sit at the slip's right edge; a hairline **red ink trace** (the voice level) runs along
  the slip's bottom edge, 1.5 px, driven by the speech timeline.
- **Thinking:** a blue dot walks down the three positions. **Speaking:** dots tick per word.
- It is not a pill; it is a bookmark tab — flat against the edge.

## Dictation slip — ≤ 460 × 100 px

- The tab pulls out into a **440 × 84 px** paper slip attached to the right edge
  (square on the right, 8 px left corners), vertically centred on the tab. Text 15 px /
  20 px, ink, 2 visible lines, scrolls inside itself.
- Provisional words in `#736D63` italic until committed; revisions cross-fade.
- Low confidence: wavy red underline (spell-check grammar — familiar). Click → a small
  paper menu under the word (≤ 90 px, 3 rows 14 px).
- Edit commands: a 13 px mono line appears at the slip's top edge — `EDIT ›` in red + the
  command in secondary ink — while it's spoken; the body edits like a proofreader:
  removed words get a red strike then collapse, inserted words appear in red then settle
  to ink. Edit 2 scrolls the slip back to line 1, edits, scrolls back.
- Delivery: the slip's text slides out into the Notion field; the slip retracts into the
  tab; a receipt tab (≤ 320 × 30) shows for ~2 s next to the bookmark, 13 px.

## Reader — ≤ 540 × 110 px — "ticker"

- The tab pulls out into a **520 × 72 px** slip. Row 1 (16 px): a **horizontal ticker**
  of the text being read — the word being spoken stays at a fixed point ~40% from the
  left; spoken words stream left and fade (so you see the tail of the previous sentence),
  upcoming words wait on the right. Continuous motion, word-accurate. Row 2 (13 px,
  secondary ink): the **next sentence** in full (truncate with …), so the upcoming
  sentence is always visible. Top-left of the slip: `FLORA` 13 px mono in blue; top-right:
  `1.1×` and pause, 13 px.

## Control center — the day timeline (≤ 30% of screen area; ≤ 1100 × 520 px)

- Slides out of the right edge as a paper sheet. Header row (13 px): `Workbench 20 ·
  Resolved · History`, right side `Grouped by project`.
- **Layout:** a left label column (240 px: status glyph + 14 px title + 13 px `Runtime`)
  and a **time axis** from 21:00 yesterday to 10:00 today (Mono 13 px ticks every 3 h,
  hairline grid). Each session is a **bar** on its row (row height 20 px, bar 8 px tall,
  ink colours by status): end time = now − `age` for finished ones; running ones extend
  to a red **"now" line at 09:41** and keep growing slowly; start = end − a plausible
  duration (define durations in your own file, 15–120 min). Needs-you = amber bar ending
  in a small amber flag at the moment it asked; failed = red bar with ✕ at its end.
  Group headers (13 px mono caps + count) separate row blocks.
- **FLORA's priorities:** blue numerals 1 2 3 in the left margin; the ask text for 1–3
  shows as a 13 px line *on the timeline* right after the bar's end (it has room there).
- Regroup → rows slide into Front-end / Back-end / Infrastructure blocks (~1 s). Resolve
  → done bars fold down into a single thin **"Resolved" track** at the bottom with 10
  ticks; counts update. Click priority 1 → its row opens (row grows to ~64 px) with the
  ask + `Approve · Not now`; "Approve it." → the bar turns green and starts growing to now.

## Automations & data streams — the week

- Same sheet: header `FLORA › Automations`. Top: a **week strip** Mon–Sun (Mono 13 px)
  with existing schedules as marks (21:37 nightly dots every day; "on push" as small
  triangles on Mon); the new `08:30 · weekdays` draws in as five red ticks, then settles
  to ink when active. Below: the draft as a compact definition list (13 px labels, 14 px
  values) + data streams as 26 px rows with **text switches** (`On` / `Off` in small
  caps). Stripe Off → On → "connected just now". `Turn it on.` → `Active · next Tue 08:30`.

## Talk + mark

- While marking, the slip is **240 × 300 px max** docked to the right edge as a vertical
  **film strip**: `● REC 0:21` (red) on top, then one frame per mark (thumbnail 96 × 54
  px + time + the 13 px words), newest at the bottom; the live words show on a single
  14 px line at the strip's bottom.
- Marks look like **pen on paper**: red ink 2.5 px with slight pressure variation,
  labels 15 px in a handwritten-feeling but legible style (use a system font with
  slight rotation ±1° — no web fonts), strike as a red ink line. Anchoring cue: small
  corner ticks snap to the element's bounds + a 13 px mono tag on a paper plate. Marks
  scroll with the page and hide/reappear with Chrome.

## Payload — the receipt

- The film strip becomes a **printed receipt** (≤ 560 × 520 px) sliding out of the
  right edge: Mono 13 px on paper, capture title on top, `0:42 · 4 marks · 4 shots`, the
  markdown lines, and the four thumbnails in its left margin next to their lines; a
  dashed "tear line" at the bottom with `Copy for any agent ⌘C · Send to…`. On ⌘C the
  receipt tears off along the dashed line and slides away toward the terminal, where the
  Claude Code prompt shows the paste.
