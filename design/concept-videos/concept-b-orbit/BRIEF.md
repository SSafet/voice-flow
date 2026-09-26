# Concept B — "Orbit"

**Thesis line (title card):** "A companion that sits where you're looking."

**Character:** spatial, luminous, alive. The signature object is a small companion that
follows your focus (text caret, pointer, the element you're marking) instead of living in
a fixed dock. Conversation, not push-to-talk: **double-tap `fn` opens the mic**, the orbit
listens until you stop, and the leading wake name ("Flora…") routes the speech. (Show a
single hold-to-talk only for scene 2's dictation *or* use the open mic throughout — pick
one and make the Key HUD consistent; open mic is preferred.) It must stay legible and
restrained — futuristic through motion and space, not through clutter or neon everywhere.

## Palette & type

- Deep ink `#07090D`; glass `#0F141B` at ≥ 94% (+ light blur at the edges only — see storyboard lessons);
  hairlines `rgba(210,230,255,.14)`.
- Text `#EAF2FF`; secondary `#AFBCCE` (≥ 7:1 on glass); inactive `#8E9BAE` (≥ 4.5:1).
- Accents: cyan `#5CE1E6` (live / listening / speech), violet `#9B8CFF` (FLORA),
  amber `#FFB547` (needs you), red `#FF6B6B` (failed), green `#7EE0A1` (ok).
- `system-ui` (SF Pro) with generous tracking in labels; `ui-monospace` (SF Mono) for
  system labels (12–13 px uppercase is allowed only for these labels) and the payload.
- Glow is a tool, not a style: only live things glow (the orbit, the spoken word, a mark
  being drawn). Everything static is flat.

## The signature object — "the triad"

- **Rest:** three 6 px dots arranged as an equilateral triangle (≈ 16 px side), docked at
  top-right under the menu bar, cool white at 80%. When you start working in a field it
  glides (curved, eased path) to sit 18 px to the right of the text caret.
- **Unread / needs you:** one dot turns amber and drifts slightly outside the triangle.
- **Listening:** the three dots orbit their centre; radius and speed follow voice
  amplitude (quiet in pauses), each dot leaving a short fading cyan trail (draw trails on a
  small canvas or with 6–8 ghost dots at decreasing opacity).
- **Thinking (FLORA):** dots tighten into a fast violet orbit.
- **Speaking (reader):** dots pulse in sequence with the spoken words.
- **Recording (talk + mark):** the triad follows the pointer at a distance of ~40 px while
  you mark; each mark fires a small "bead" that flies from the mark into the triad.
- All surfaces unfold *from the triad's position* (scale/clip from that point) and fold back into it.

## Transcript lens (dictation)

- A compact glass capsule attached to the triad next to the caret: 540 px wide, 20 px
  radius, 3 visible lines, 21 px / 1.45, `#EAF2FF`. It floats near the Notion field —
  close to where the text will go, but not covering it.
- **Streaming:** words *focus-pull* in — each new word starts blurred (6 px) at 50%
  opacity and sharpens over ~200 ms; provisional words have a faint cyan tint until
  committed; a revision morphs letters (blur-swap) in place.
- **Low confidence:** the word is outlined by a soft cyan underglow. Click → alternatives
  fan out *vertically from the word* like a small picker drum (3 rows, the chosen one in
  the centre, 18 px), with the triad momentarily attached to it.
- **Edit commands:** while spoken, the command streams in the lens footer in violet with
  a `↺` glyph (15 px). Then the target phrase **lifts** out of the line (translateY −10 px,
  glow), the words swap in the air, and it drops back; inserted word glows cyan and cools.
  Edit 2: the lens scrolls smoothly back to line 1 (show a thin position rail on the
  lens's right edge), lifts & swaps, scrolls back.
- **Delivery:** the text streams into the Notion field as a light-trail from the lens to
  the caret; lens folds into the triad; one-line receipt next to the triad.

## Reader (text-to-speech) — "the drum"

- A wider lens (760 px) unfolds above the triad. Sentences sit on a **3-D drum** (CSS
  `perspective` + `rotateX`): the current sentence faces you at 26 px; the previous one is
  tipped away above (rotateX ≈ 38°, 18 px, dimmer), the next is tipped below (rotateX
  ≈ −38°). The drum turns **continuously** with the reading position (not snapping), like
  a scroll wheel. Words brighten cyan-white as spoken; the spoken word has a soft glow.
- Speaker label `FLORA` in violet, SF Mono 12 px; `1.1×` and pause at the right, 15 px.

## Control center — "constellation"

- Full-screen overlay: the desktop dims (ink at 78% + blur 18 px). The triad moves to the
  screen centre-left; FLORA's voice commands stream in a small lens under it.
- **Clusters, not lists:** each group is a loose constellation of nodes (8 px dots) with a
  large, light group title (34 px, weight 300, `#EAF2FF`) and a count. Each node has a
  label beside it: title 16 px + one 14 px meta line (`Runtime · age`). Node states: needs
  = amber dot with a slow ring; failed = red dot; review = amber hollow ring; running =
  cyan dot with a tiny orbiting spark; idle = hollow dot; done = small hollow ring, dim.
  Arrange nodes on gentle arcs so labels never collide — legibility beats organic chaos.
- **Priorities:** thin violet light-lines from the triad to the three priority nodes,
  numbered `1 2 3` where the line meets the node.
- **Focus rail** (right, 380 px, glass): FLORA's three priorities as text rows, and the
  selected session's detail. Header text controls: `Workbench 20 · Resolved · All` and
  `grouped by project` (updates when regrouped).
- **Regroup:** nodes fly along curved paths into the three new clusters (~1.3 s,
  staggered), titles cross-fade.
- **Resolve:** done nodes contract into beads and stream into a small `Resolved` ring at
  the bottom-left whose counter ticks to 10; remaining nodes relax into the freed space.
- **Detail / approve:** clicking priority 1 focuses it (others dim), the focus rail shows
  the ask (title 20 px, body 16 px, `Approve` / `Not now` as quiet text actions); on
  "Approve it." the node's state morphs to running.

## Automations & streams — "FLORA's orbit"

- In the constellation, FLORA's own node (violet, larger, centre) expands into a profile:
  a **24-hour ring** around it with existing schedules as ticks (21:37, "on push") and the
  new `08:30 · weekdays` tick drawing in; **data streams as satellites** connected to FLORA
  by lines — on = solid lit line, off = dotted dim line; Stripe goes dotted→lit when
  spoken. The focus rail shows the draft as text (label 13 px mono uppercase / value 18 px),
  filling field by field. `Turn it on.` → `Active · next Tue 08:30`. Show freshness text
  next to each satellite (14 px).

## Annotations

- Strokes: cyan `#5CE1E6` 3 px with a subtle 6 px glow while being drawn, settling to flat
  after; labels 22 px semibold cyan-white on a soft dark halo; strike in amber.
- **Anchoring cue:** the target element gets four corner brackets that snap onto its
  bounds (scale from 1.1 → 1.0, ~250 ms) plus a small SF Mono tag `anchored · meal-card`,
  then fade; a hairline tether stays from the mark to its element while the capture runs.
- Voice-only marks: the triad flies to the target, the label types itself in / the strike
  draws itself, the triad returns to the pointer.
- **Capture record:** a vertical "trail" on the right edge: each mark adds a row (time,
  said words 15 px, 80 px thumbnail), newest at the bottom, beads flying in.

## Payload

- The trail gathers into a **packet**: the 4 screenshots as a slightly fanned 3-D stack on
  the left, the markdown (SF Mono 15 px) on the right, header with the capture title and
  `0:42 · 4 marks · 4 shots`, quiet actions `Copy for any agent ⌘C` and `Send to…`.
- On `⌘C` the packet compresses into a single glowing bead that travels to the terminal,
  where the Claude Code prompt shows the paste.
