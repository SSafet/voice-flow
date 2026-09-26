# Concept A — "Horizon"

**Thesis line (title card):** "Everything you say lands on one line."

**Character:** calm, editorial, edge-anchored. A premium instrument, not a gadget. The
product lives at the bottom-centre edge of the screen and never moves; everything grows
upward out of a single hairline. Push-to-talk precision: **hold `fn` to talk**, release to
deliver. Typography does all the work.

## Palette & type

- Graphite `#0E0D0C` (surfaces ≥ 94% opaque; blur only softens edges — see storyboard lessons),
  raised `#1A1917`, hairlines `rgba(255,248,235,.14)`.
- Text `#F3F0E9`; secondary `#BDB7AB` (≥ 7:1 on graphite); tertiary/inactive `#9C968B` (≥ 4.5:1).
- Accent amber `#F5A524` (the brand's existing amber), success `#86C98A`, danger `#FF7A6B`.
- `system-ui` (SF Pro) for everything; `ui-monospace` (SF Mono) only for code/payload.
  Uppercase labels: 13 px, letter-spacing .12em, `#BDB7AB`.

## The signature object — "the horizon"

- **Rest:** three 6 px dots, 12 px apart, sitting *on* a 1 px hairline that fades out to
  both sides (≈ 150 px total). Bottom-centre, 28 px above the screen's bottom edge. No
  container, no pill. Dots `#F3F0E9` at 85%.
- **Unread / needs you:** the middle dot is amber with a 1 px amber ring 4 px out; static
  (a waiting *question* would breathe slowly — not needed here).
- **Listening:** the hairline extends smoothly to the width of the transcript lane
  (≈ 760 px) and *becomes the waveform* — the line itself undulates with voice amplitude
  (smooth, low amplitude, ±6 px, driven by `K.noise` + the speech timeline so it's quiet in
  pauses). The dots slide to the line's left end and turn amber = "live".
- **Thinking (FLORA):** the line contracts to ≈ 200 px and a soft light travels along it.
- **Speaking (reader):** the line is a progress rule — the read part brighter than the rest.
- **Recording (talk + mark):** the line becomes the capture's timeline: each mark drops a
  small amber tick onto the line at its time.
- Everything else (lane, reader, deck, payload) rises *out of the line* (clip/translate
  from the line upward) and sinks back into it.

## Transcript lane (dictation)

- Floats directly above the line with **no visible box**: a solid graphite field (96%
  opaque behind the text) whose edges feather out over ~28 px — no border, no visible
  corners — so it reads as the line's own light, and stays legible over bright Notion.
  Max width 760 px, centred, 2 visible lines, 26 px / 1.38, `#F3F0E9`.
- **Streaming:** committed words solid; the last 1–3 provisional words at 60% opacity with
  a slow shimmer; a revision cross-fades the old word into the new one in place.
- **Low confidence:** 1.5 px dotted amber underline. Click → a tiny inline menu *under the
  word* (not a card): three alternatives as plain text rows, 17 px, the first highlighted,
  separated by hairlines; then a one-line note in the lane's footer.
- **Edit commands:** while an edit is being said it streams on a separate *command line*
  above the text, 15 px, prefixed by a small uppercase amber `EDIT` label, so the viewer
  sees it's a command, not text. Then the body edits in place: removed words get a
  strike that collapses their width to zero; inserted words appear amber and settle to
  white over ~1.2 s. For edit 2 the lane scrolls smoothly back to the first line, edits,
  and scrolls back to the end with the caret.
- **Delivery:** on key release the lane's text lifts and flies (scale-down, fade) into the
  Notion Description field, where it appears; the line collapses to rest; a one-line
  receipt sits on the horizon for ~2 s (`Sent to Notion · PT-141 Description`), 15 px.

## Reader (text-to-speech) — "teleprompter"

- Same place as the lane, same width: three rows. Previous sentence 19 px `#BDB7AB`
  above; current sentence 28 px — words already spoken `#F3F0E9`, the word being spoken
  amber, words to come `#A9A398`; next sentence 19 px `#9C968B` below. Continuous upward
  motion between sentences (the current row glides up and shrinks to "previous" size while
  the next grows into place) — never a cut.
- Speaker line above the rows: `FLORA` in 13 px uppercase amber + `1.1×` and a pause glyph
  at the right end, 15 px, quiet. Nothing else.

## Control center — "the deck"

- Rises from the horizon: a wide bottom-anchored sheet, 1480 × 600, solid graphite (96%), one
  hairline top edge, 16 px radius on the sheet only. The horizon stays below it as the
  command line (voice commands stream into it).
- **Header row** (text only): `Workbench 20` · `Resolved` · `History` as text tabs (active
  = white + 2 px amber underline), right side `Group: Project ▾` and a quiet search glyph.
- **Body: typographic columns** like a newspaper — one column per group with a 13 px
  uppercase header + count, hairline vertical dividers between columns, no cards. A
  session = one row: status glyph (8 px), title 17 px `#F3F0E9`, then a 14 px meta line
  `Runtime · age · line` in `#BDB7AB`. Status glyphs: needs = filled amber dot, failed =
  red ✕, review = amber hollow ring, running = small rotating arc (amber), idle = hollow
  grey dot, done = muted check.
- **FLORA's priorities**: large amber numerals `1 2 3` (30 px, light weight) hanging in the
  left margin of those rows.
- **Regroup**: rows FLIP-animate from old column to new column (staggered 40 ms, curved
  paths, ~1.1 s); column headers cross-fade.
- **Resolve**: each done row gets a check, fades, its height collapses; `Resolved` tab
  counter ticks up to 10, `Workbench` ticks down to 10.
- **Detail**: clicking a row expands it *in place* in its column (rows below slide down):
  the ask title 20 px, body 16 px, and two quiet text actions `Approve` / `Not now`. On
  "Approve it." the status glyph morphs to running and the line becomes the approved line.

## Automations & streams (inside the deck)

- The deck header shows `FLORA` › `Automations`. Left third: the automation list (name 17 px,
  schedule 14 px). Right two-thirds: the draft as a **definition list** — uppercase 13 px
  labels in a left column, 20 px values on the right, hairlines between rows. Fields fill
  in one after another as FLORA "writes" them.
- Data streams as rows: name 17 px, detail + freshness 14 px, and a small text switch at
  the right (`On` amber / `Off` grey — text, not a big toggle). Stripe flips from Off to On
  when spoken. `Turn it on.` → the automation's status word goes amber `Active · next Tue 08:30`.

## Annotations

- Ink: amber `#F5A524` strokes, 3 px, round caps, slight hand-drawn irregularity; labels in
  22 px SF Pro semibold amber with a soft dark halo (no box).
- **Anchoring cue:** when a mark attaches, a 1 px dashed amber outline hugs the element's
  bounds for ~0.7 s and a small `⌖ meal-card · Tue` tag (13 px) appears at the outline's
  corner, then both fade — the mark stays.
- Voice marks draw themselves (label types in; strike line draws left→right).
- The capture record lives on the horizon line: a tick per mark; above each tick a 96 px
  thumbnail rises for 1.5 s when the mark is made, then settles as a tick.

## Payload

- The deck rises again showing the payload: left column the four thumbnails stacked with
  their times; right the markdown in SF Mono 15 px. Header: capture title + `0:42 · 4 marks
  · 4 shots` and two quiet text actions: `Copy for any agent  ⌘C` and `Send to…`.
- On `⌘C` the deck folds down into the line and a receipt says `Copied for any agent`; the
  terminal window comes forward and the paste appears at the Claude Code prompt.
