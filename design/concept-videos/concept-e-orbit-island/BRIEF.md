# Concept E — "Orbit Island" (Safet's synthesis of B + C)

**Thesis line (title card):** "Words in the notch. It listens where you work."

Safet's decision after seeing A–D: **Orbit (B) almost 100%**, with C's notch island as the
home for words, B's triad travelling to where he works, and none of B's oversized
floating panels or dark shadows. Read `shared/storyboard.md` (Space budget + lessons),
then `concept-b-orbit/BRIEF.md` and `concept-c-island/BRIEF.md` — this brief only says
what comes from where and what changes.

## Start from code, don't rebuild

Copy `concept-b-orbit/` into this folder as the base (film structure, desktop, triad /
orbit canvas, constellation, FLORA's 24-hour automation ring, capture marks). Bring in
C's island mechanics from `concept-c-island/` (notched menu bar, island grow shapes and
shoulders, whole-line scrolling with motion-only fades, 3-line lyrics reader, receipts,
REC line with pips, thumbnail drop, welded alternatives drop-down). Do not edit the B or
C folders.

## What comes from where

| Element | Source | Notes |
|---|---|---|
| Palette, motion language, open mic (`fn fn`), wake name routing | **B** | cyan `#5CE1E6` live · violet `#9B8CFF` FLORA · amber needs-you · B's text colours |
| Notch + island (the only place words appear while talking/reading) | **C** | island is flat `#000`, welded to the top edge; C's sizes |
| The triad (three dots in a triangle, orbit animation, trails) | **B** | rests *in the notch*; travels to where you work (below) |
| Dictation text, voice edits, misheard-word picker | **C size, B motion** | 15 px; B's focus-pull word arrival and lift-and-swap edits, scaled to the island (lift ≈ 4 px) |
| Reader | **C** (3 whole lines, 540 × 128) | B colours: spoken word cyan-white with a faint glow, others per B |
| Control center (constellation, focus rail, regroup, resolve, approve) | **B, unchanged** | full screen is liked — keep it |
| Automations (FLORA's 24-hour ring, data-stream satellites, rail) | **B, unchanged** | full screen is liked — keep it |
| Voice commands during control center / automations | **island** | the spoken command streams in the island (it stays visible above the dimmed overlay) instead of B's bottom-left lens — one place for words |
| Talk + mark capture record | **C** | REC line + one pip per mark in the island, thumbnail drops out and shrinks into its pip; B's cyan strokes, corner-bracket anchoring and tethers on the page |
| Payload | **C size + B stack** | drops from the island (≤ 900 × 340): B's fanned screenshot stack, compact, + markdown; ⌘C folds it into the island and B's bead flies to the terminal |

## The triad's journey (the new behaviour)

- **Rest:** the triangle triad (5 px dots, ~12 px triangle) sits inside the notch, cool
  white at 80%. **Unread:** one dot amber, drifting slightly outside the triangle (B).
- **Talking starts (`fn fn`):** the triad leaves the notch on a curved, eased path
  (~0.6 s) to the point of work:
  - **a text field has focus** (Notion Description in scene 2; the Claude Code prompt in
    scene 7 if there is speech there) → it sits 14 px right of the text caret and moves
    with the caret as text lands;
  - **otherwise** → it follows the mouse pointer at ~28 px offset with a soft spring lag.
- **Listening:** B's orbit (radius/speed from the speech amplitude, short cyan trails).
  **Thinking:** B's tight violet orbit. **Speaking (reader):** it returns to the notch
  and pulses there per word (you're reading at the top).
- **Talking ends:** it flies back into the notch (~0.5 s). In the control center and
  automations it plays B's hub role exactly as in B.
- The island at the top shows the words; the triad at the point of work shows "I'm
  listening". Make that relationship readable: when the triad arrives at the caret, the
  island grows at the same moment; while it listens, both are live together.

## Shadows — hard rule (Safet's feedback on B and A)

Safet disliked the big dark shadows / feathered dark haze behind B's lens and drum and
A's reader. Outside the full-screen control center and automations:
- **No drop shadows, glows, dark halos or feathered scrims behind any VoiceFlow surface.**
- The island is flat black welded to the screen edge — no shadow at all.
- Drop-downs welded to the island (alternatives, payload, receipts) may have a 1 px
  hairline `rgba(255,255,255,.10)` and at most a tight `0 2px 6px rgba(0,0,0,.25)` shadow.
- Desktop app windows keep a subtle, standard macOS window shadow; no window may peek
  out behind another as a dark block (lay the desktop out cleanly).

## Space budget

Same as C (storyboard): dictation ≤ 460 × 100, alternatives ≤ +90, reader ≤ 540 × 128,
receipts ≤ 360 × 32, capture record inside the island, payload ≤ 30% of the screen,
VoiceFlow text ≤ 16 px. Control center and automations are exempt (full screen by
Safet's choice). Ship `check-budget.mjs` (adapt C's) and pass it.
