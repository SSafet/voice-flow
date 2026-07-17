# Panel redesign — Safet's design remarks (ticket #15)

The binding checklist distilled from the design review of `panel-redesign.html`.
Every panel change MUST be audited against this list before handing back —
violations of remarks already given are worse than new bugs.

## Global
1. No "Start session" anywhere in the panel (pill/menu/hotkey own that).
2. No metadata anywhere — timestamps exist ONLY in the Agents session list.
3. No status pills/badges; destination is invisible data (filter chips are its
   only surface).
4. No decorations: no amber edge bars, no number circles, no double rings,
   no glow dots. Unread = the row simply reads bright.
5. The pill's ⌃⌥1–9 flow is the primary notification surface — panel changes
   must never alter pill behavior.
6. Fixed panel geometry — content must truncate, never stretch the window.

## Inbox tab
7. Rows are nothing but the words (no time, no destination text, no action
   buttons/icons). Click = copy (+ marks a kept item revisited).
8. Filters: All / Kept / Pasted / Assistant chips; Kept chip counts
   unrevisited items.
9. Kept unrevisited items read bright; everything else quiet.

## Agents tab
10. Root = minimal latest-first list; assistant is a persistent FIRST row
    wearing the VoiceFlow waveform icon (never a number, never green ✦).
11. Sessions show plain muted digits ≡ pill picker numbering; ghosts persist
    until read.
12. Click pushes the thread over the list (master-detail); ⌃⌥N deep-links.
13. Thread header = quiet nav bar: ‹ back left, centered title, 🔊 right,
    hairline below.
14. Threads are FLAT: no cards, no repeated sender names, no "asks"/"you"
    bubbles. A push is ONE block, question or not.
15. The composer attached to an unanswered ask IS the ask signal; the answer
    then attaches beneath it (↳), in chronological place; otherwise a single
    composer sits at the bottom.
16. The assistant thread is the old Chat (type/snap/talk composer at the
    bottom); ↳ marks the user's words.

## Speech
17. Speech is a utility (♪ toggle), never a peer tab. Audio never auto-plays.
