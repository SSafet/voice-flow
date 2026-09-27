# VoiceFlow concept films — shared storyboard

Two films, one per design direction, telling the **same story with the same data**
(`shared/data.js`) so Safet can compare the directions shot for shot. Each film is a
single HTML page rendered frame-by-frame by `shared/render.mjs` (read its header).
Target length **3:00–3:40**, 1920×1080, 30 fps, silent (no audio track).

## The product in one paragraph

VoiceFlow is the voice-and-screen layer between one person and every agent they run.
Hands-free first: you press one key and talk, and a small surface shows exactly the words
in flight (streaming speech-to-text) or the sentence being read to you (text-to-speech),
so you can correct a misheard word the moment you see it. Anything you said can be fixed
by saying so. FLORA, the personal agent, sees every coding/cloud agent you run and keeps a
clean workbench of them. Screen annotations stick to the element you meant, and a talk-and-
mark session becomes one portable payload any agent can read.

## Governing principles (both directions must honour these)

1. **Hands-free first.** The resting state is three dots. Surfaces appear only while
   speech is happening and only as big as the words need. Nothing steals keyboard focus.
2. **One signature object.** The pill is gone; the three dots remain and *become*
   everything (listening, thinking, speaking, unread, recording). Every other surface grows
   out of it and returns into it — nothing pops up unrelated.
3. **Text is the interface.** Hierarchy through typography, whitespace, alignment and
   hairlines. Do not put every item in a rounded rectangle; containers only where a
   surface must separate from the desktop. Buttons are quieter than the content.
4. **Legible.** Product text ≥ 15 px (meta ≥ 14 px, the one allowed exception: 13 px
   uppercase letter-spaced labels). Reading text 20–30 px. Secondary text contrast ≥ 7:1,
   never faded grey on dark; placeholder/inactive ≥ 4.5:1.
   **Concepts C and D override the sizes here — see "Space budget" below.**
5. **Every spoken word is editable by speaking.** Edit commands are never inserted as text.
6. **Marks belong to elements, not pixels.** They scroll with content and hide with their window.
7. **Everything becomes an agent-readable record.** Transcript + marks + screenshots, in order.

## Space budget — Concepts C and D (hard rules, from Safet's review of A and B)

A and B used 26 px text and surfaces that covered a large part of the screen while
dictating. Safet: be far more mindful of the space elements take. For C and D:

- **Native-scale type.** The film's 1920×1080 frame is a MacBook screen; native macOS UI
  text is ~13 px there. Product text is **14–15 px**, meta/labels **13 px** (never
  smaller), the reader's current sentence **16 px max**. Nothing in a VoiceFlow surface
  is larger than 16 px except the title card and chapter captions.
- **Dictation surface ≤ 460 × 100 px** (≈ 2% of the screen) including any command line;
  2 text lines visible (it scrolls inside itself). Alternatives menu adds ≤ 90 px while open.
- **Reader surface ≤ 540 × 110 px.**
- **Receipts / one-liners ≤ 360 × 32 px.**
- **Control center / automations / payload** (deliberately summoned): ≤ 30% of the
  screen area (e.g. 900 × 560), information-dense like a native popover, not a full-screen takeover.
- **Capture record while marking:** ≤ 260 × 320 px, or inside the signature object.
- Validate it: at the key frame of every scene, measure each VoiceFlow surface with
  `getBoundingClientRect()` in the page and fail your own review if any budget is exceeded.
  Report the measured maxima.

## Lessons from past VoiceFlow design reviews (hard rules)

- **Pitfalls found in A/B reviews:** text-carrying surfaces must be ≥ 98% opaque (A and B
  first shipped see-through); feathered edges must be smooth on every side; priority rows
  must show the full ask (never truncate it); after Stripe is switched on its detail reads
  "connected just now", not "not connected yet"; payload filename columns align.

- **Solid dark, not see-through.** VF-16 moved the panel from translucent blur to solid
  dark because it washed out over bright pages (Notion and Pantrella are bright). Any
  surface that carries text must be ≥ 94% opaque dark behind the text. Blur may soften the
  edges; it must never be what provides contrast.
- **No hairline under or through reading text** — VF-48's progress hairline "read as a
  strikethrough". Progress lives in the signature object, not under words.
- **One visualization per action, one quiet cue per state** — no decorative glyph +
  underline + colour on the same word; pick one (VF-48 "overcrowding").
- **Nothing auto-hides while being read.** Surfaces leave only on an explicit action or
  when their job is done (delivery, end of reading).
- **No card/bubble per item, no number circles, no edge bars** (VF-16 review). Rows are
  flat text; unread = brighter/semibold; counts are plain digits.
- **Karaoke moves smoothly**, Apple-Music-lyrics style — VF-48 rejected text that swaps abruptly.
- **Patterns come from products people already use** (VF-48/49): when you invent an
  interaction, it should echo something familiar (iOS picker, Apple Music lyrics,
  newspaper columns, Linear lists, Figma comments…).

## Film furniture (both films)

- **Desktop.** A believable macOS desktop: menu bar with clock `Mon 28 Sep  09:41`, a dark
  quiet wallpaper, real-looking app windows drawn in HTML/CSS: **Notion** (Pantrella ·
  Tickets, ticket PT-141), **Chrome** with the Pantrella web app (`app.pantrella.com/plan`,
  weekly plan from data.js — warm off-white app UI with a green accent, like the real one)
  and a short article page for scene 3b, and a **terminal** running Claude Code for the
  hand-off. Windows need traffic lights, title bars, believable density. No Dock needed.
- **Pointer.** A macOS arrow cursor that moves on eased paths, with a small press ripple on
  clicks. It must look intentional (no teleporting).
- **Key HUD.** Bottom-left, a small keycap strip showing what the user presses and holds
  (`fn` held · `fn fn` double-tap · `⌘C` · `⌘⇥` · `esc`), so the interaction is readable
  in a silent film. Fades out when nothing is pressed.
- **Chapter caption.** Top-left under the menu bar: a 13 px uppercase letter-spaced
  chapter label + one 22 px sentence that states the capability. Visible ~3 s at each
  chapter start, then fades to a small persistent chapter label. It must never cover the
  product surfaces.
- **Speech is shown by the product.** Silent film: everything the user says must be
  visible *because the product displays it while it is being said* (streaming). If a
  command is spoken while no transcript surface is visible, the product must show it.

## Scenes (times are targets; ±20% is fine, keep the order)

| # | Time | Scene | Must show |
|---|------|-------|-----------|
| 0 | 0:00–0:04 | Title | "VoiceFlow" + concept name + one-line thesis. Quiet, typographic. |
| 1 | 0:04–0:10 | At rest | The signature object resting on the desktop over real work. One unread (a session waiting) shown by the object's quiet unread cue. Chapter: "Three dots. Always there, never in the way." |
| 2 | 0:10–0:55 | Dictation, streaming + voice editing | User clicks the Notion ticket's Description field, holds the talk key. **Utterance 1** streams word-by-word with partial hypotheses visibly revising (`on boarding`→`onboarding`, `describe a desk`→`describe a task`); unstable words look provisional until committed. Pause. **Edit 1** is spoken: the product shows it is an edit (not text), and the body changes in place — `a question` → `ask a question`, the inserted word highlighted, then settles. **Utterance 3** streams with `pantry la` flagged as low-confidence. The pointer clicks it: three alternatives; picks **Pantrella**; a one-line "added to your vocabulary" cue. **Edit 2** targets the *start*: the surface scrolls back to the beginning, replaces `The onboarding chat` → `The first-run chat`, then returns to the end ready to continue. Key released → the final text is delivered into the Notion field, one-line receipt. |
| 3 | 0:55–1:25 | Talking to FLORA + the reader | User holds the key: the ask streams; the leading "Flora" is recognised as a wake name and the surface visibly routes to FLORA. Thinking state with `thinking` line from data.js. FLORA replies: the **reader** plays the 5 reply sentences with word-level progress — the previous sentence visible above, the current one prominent, the next visible below; sentences move smoothly (continuous motion, no hard cuts). Minimal controls: pause and a speed value (e.g. 1.1×) — nothing else. User says "Show me." |
| 3b | (inside 3, ~7 s) | Same reader for any text | In Chrome on the article, the user selects the 3 article sentences and presses `F8`: the same reader reads them. Caption: "Every voice, same reader." (This scene may come before "Show me." or right after scene 3; keep total pacing tight.) |
| 4 | 1:25–2:05 | Control center | FLORA's surface opens into the control center: all 20 sessions grouped **by project**, statuses legible, runtimes (Codex / Claude Code / Cloud) visible, FLORA's priorities 1–3 marked. Spoken **regroup** → sessions animate into Front-end / Back-end / Infrastructure. Spoken **resolve** → the 10 done sessions visibly leave the workbench into a Resolved count; the workbench is now 10 items. Pointer clicks "Resolved" to glance at them, then back to Workbench. Pointer opens priority 1 (checkout): its ask from data.js; user says "Approve it." → status turns to running. |
| 5 | 2:05–2:35 | FLORA's automations + data streams | User speaks the automation request. FLORA drafts it field by field (name, schedule, delivery, access, data streams with on/off). User says "Also include Stripe payouts." → Stripe stream turns on. "Turn it on." → active; the automation list shows it with the two existing ones and "next run Tue 08:30". A glance at all data streams with freshness (data.js `streams` + `otherStreams`), each with a quiet on/off. |
| 6 | 2:35–3:15 | Talk + annotate, anchored | Chrome, Pantrella weekly plan. User starts talk-and-mark (key HUD shows the gesture). Following data.js `annotations`: pointer draws a circle around the Tue card while the words stream; the mark **snaps/anchors to the element** (visible anchoring cue). Arrow to the Shopping-list button. Then **voice-only** marks: the label appears under the button by itself; the Wed "540 kcal" gets struck through by itself. Each mark adds an entry (time + words + a thumbnail screenshot) to the capture record. User scrolls the page: marks move with their elements. `⌘⇥` to Notion: marks disappear with Chrome; `⌘⇥` back: they reappear exactly in place. |
| 7 | 3:15–3:35 | One payload, any agent | Capture stops: a summary line (0:42 · 4 marks · 4 shots) and the payload preview (data.js `payloadMarkdown`, with the 4 thumbnails). `⌘C` "Copy for any agent" → the terminal: Claude Code prompt receives the paste (data.js `handoff.pastedLine`). |
| 8 | 3:35–3:42 | End card | The five end-card lines, then "VoiceFlow · Concept X". |

## Realism rules

- Speech rate ~2.6–3 words/s with natural pauses (use `K.speechTimeline`). Streaming text
  appears as words are spoken, never faster.
- Every state change is animated (≥ 150 ms, eased); no hard cuts except scene 0→1.
- Hold key moments long enough to read: a new surface state should sit still ≥ 1.2 s before the next change.
- Timings must feel like a real person operating a real product, not a slideshow.
