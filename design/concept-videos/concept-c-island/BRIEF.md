# Concept C — "Island"

**Thesis line (title card):** "It lives in the notch."

**Character:** native, quiet, Apple-grade. VoiceFlow takes over the one piece of the
MacBook screen nobody uses — the camera notch — and grows out of it the way the iPhone's
Dynamic Island grows out of the camera cut-out. It never floats over your work; it hangs
from the top edge and pulls back up when done. Hold `fn` to talk (push-to-talk).

Read `shared/storyboard.md` first — especially **Space budget** (hard) and the lessons.

## The notch & the signature object

- Draw a real MacBook notch in the film's menu bar: centred, **190 × 32 px**, pure
  `#000`, flat top flush with the screen edge, 10 px bottom corners. The menu bar (24 px,
  translucent dark like macOS) runs on either side of it; menu items stay clear of it.
- **It is not a pill.** The island's shape is always *the notch, extended*: flat top
  welded to the screen edge, two small concave "shoulder" curves (6 px) where it meets the
  menu bar, rounded bottom corners (14 px when grown). Growing = the notch getting wider
  and deeper; never a detached capsule.
- **Rest:** the three dots (4 px, 7 px apart, `#F5F5F7` at 80%) sit in the notch's lower
  right area, inside the black, like a status light. **Unread:** the middle dot is amber
  `#FFB340` with a static ring.
- **Listening:** the island grows (spring, ~350 ms) to its dictation size; the three dots
  move to the left shoulder and turn **orange `#FF9F0A`** — the macOS "mic in use" colour.
  A 5-bar mini level meter (≤ 18 px tall) sits at the right edge, driven by the speech timeline.
- **Thinking (FLORA):** indigo `#7D7AFF` dots chasing in a 3-dot loop; one line of text.
- **Speaking:** dots pulse on each word.

## Dictation — size budget ≤ 460 × 100 px (including the notch height)

- Island grows to **440 × 92 px** (32 px notch band + 60 px text area). Text 15 px / 20 px
  line height, `#F5F5F7`, 2 visible lines, left-aligned with 18 px side padding; it scrolls
  up inside the island as lines fill (smooth).
- Streaming: committed words solid; provisional words `#A1A1A6` until they commit; a
  revision cross-fades in place.
- Low confidence: dotted underline in amber. Click → an attached drop-down directly
  under the island (same black, welded, ≤ 90 px): 3 alternatives as 14 px rows.
- Edit commands: the island's notch band (the top 32 px, left of centre) shows `EDIT` in
  13 px amber small caps followed by the command text in 13 px `#D1D1D6` (truncate from
  the left if long) while it's spoken — the command never enters the body. The body then
  edits in place: removed words collapse, inserted words flash amber then settle.
  Edit 2 scrolls the 2-line window smoothly back to the start, edits, scrolls back.
- Delivery on key release: the text drops as a thin light trail from the island into the
  Notion field (where the text appears), the island retracts into the notch; a receipt
  hangs from the notch for ~2 s: 320 × 32 px max, 13 px.

## Reader — ≤ 540 × 110 px

- Island grows to **520 × 104 px**: notch band carries `FLORA` (13 px small caps,
  indigo) on the left shoulder and `1.1×` + pause on the right (13 px). Below, a 3-line
  lyrics view: previous sentence 13 px `#A1A1A6`, current 16 px `#F5F5F7` with the spoken
  word in white and upcoming words `#C7C7CC`, next 13 px `#8E8E93`. Long sentences wrap
  to 2 lines — let the view scroll smoothly by the reading position (Apple Music lyrics),
  never jump.

## Control center — drops down from the island (≤ 30% of screen)

- Like macOS Notification Center, but hanging from the notch: the island widens into
  the top edge of a **900 × 560 px** dark sheet (`#1C1C1E` at 98%, 14 px bottom radius,
  subtle shadow) — continuous with the island, no gap.
- Header (single row, 13 px): `Workbench 20 · Resolved · History` text tabs, right side
  `Grouped by project ▾`; FLORA's command line lives in the island itself.
- Body: groups flow in **two columns**. Group header 13 px small caps + count. Each
  session is **one 28 px row**: status glyph (7 px), title 14 px `#F5F5F7`, right-aligned
  13 px meta `Runtime · age` in `#AEAEB2`. Priority rows 1–3 get the digit in amber (14 px,
  in the left gutter) and a second 13 px line with the full ask/reason.
- Regroup → rows FLIP into Front-end / Back-end / Infrastructure (~1 s, staggered).
  Resolve → done rows fold away; tab counts tick (Workbench 10, Resolved 10). Detail:
  clicking priority 1 expands it in place (ask title 14 px semibold, body 13 px, quiet
  text actions `Approve · Not now`); "Approve it." turns it running.

## Automations & data streams — same drop-down sheet

- Header breadcrumb `FLORA › Automations`. Left 280 px: automation list (14 px name,
  13 px schedule). Right: the draft as a compact definition list (13 px labels, 14 px
  values), filling field by field; data streams as 28 px rows with a small native-style
  switch (28 × 16 px). Stripe: Off → On → "connected just now". `Turn it on.` →
  `Active · next Tue 08:30`. Then a short glance at all streams with freshness.

## Talk + mark

- While marking, the island stays small: **360 × 64 px** — `● REC 0:21` (13 px, orange
  dot) on the left shoulder, the live words on one 14 px line below (scrolling
  horizontally, newest right), and **one numbered pip per mark** on the right shoulder.
  When a mark is made, a 120 × 68 px thumbnail drops out of the island for ~1.2 s and
  shrinks into its pip.
- Marks: 2.5 px ink in `#FF9F0A`, labels 15 px semibold with a dark halo, strike in red.
  Anchoring cue: 1 px dashed outline hugging the element for 0.6 s + a 13 px tag on a
  solid dark plate (`anchored · meal-card`). Marks scroll with content and hide/reappear
  with the Chrome window (storyboard scene 6).

## Payload

- The drop-down sheet (≤ 900 × 520) shows the capture: 4 thumbnails as a vertical strip
  (160 px wide) on the left with times, the markdown in SF Mono 13 px on the right,
  header with title + `0:42 · 4 marks · 4 shots` and quiet `Copy for any agent ⌘C · Send to…`.
  On ⌘C the sheet retracts into the notch; receipt; the terminal shows the paste.

## Palette

`#000` island · `#1C1C1E` sheets · text `#F5F5F7` · secondary `#AEAEB2` (≥ 7:1 on
`#1C1C1E`) · tertiary `#8E8E93` · live `#FF9F0A` · needs-you `#FFB340` · FLORA `#7D7AFF`
· running `#64D2FF` · failed `#FF453A` · done `#98989D` · hairlines `rgba(255,255,255,.10)`.
`system-ui` (SF Pro) throughout; Menlo/SF Mono for the payload.
