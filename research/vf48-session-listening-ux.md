# VF-48 — Session player + consumable notifications: product-pattern research

Produced 2026-07-29 by a 6-agent research sweep (5 component researchers + 1
adversarial completeness critic) over shipped mainstream products. Every
component of the VF-48 redesign is mapped to the existing products whose
interaction pattern it borrows, per the ticket's "tried and true, users already
know it" rule. Full structured findings preserved in the session workflow
journal; this is the distilled evidence the design is built on.

The five "steal this" verdicts — the strongest pattern per component:

| Component | Borrow from | The pattern |
|---|---|---|
| Mini player | **Telegram pinned playback bar** | One always-on-top strip: play/pause + what's-playing label + cycling speed chip + ✕ = stop-and-dismiss (content remains). Tapping the label opens the source, never toggles playback. |
| Transport hotkey | **AirPods stem grammar** | ONE global hotkey, press-count semantics: 1 press = pause/resume, 2 = skip forward, 3 = skip back, hold = stop. Identical across Apple/Bose/generic BT — zero teaching needed. VF already ships double-press detection. |
| Consumption | **Podcast three-state (Pocket Casts / Apple Podcasts)** | unplayed → in-progress (persisted resume position, remaining shown) → played only at finish (~95%). Finished items auto-leave the working queue (Up Next = pill stack) but never leave history. Users treat early mark-played as a bug. |
| Chronological browse | **iPhone Visual Voicemail** | Flat reverse-chronological list; listening clears the blue dot but the row NEVER moves — consumed and new interleave in one timeline; rows expand inline into a mini player with the transcript; delete = recoverable end-of-list bin. The whole VF-48 shape in one 2007-vintage surface. |
| Live read-along text | **Spotify lyrics + teleprompter + Netflix caption specs** | Sentence-level karaoke (line granularity reads as complete without word timestamps — never estimate word timing you don't have); fixed focal row, text scrolls through it; ~40 chars/line, 2 bright lines, clause-boundary breaks, ≥1 s dwell. |

## 1 · Mini player + transport

Products: Apple Podcasts, Overcast, Pocket Casts, Audible, WhatsApp/Telegram
voice messages, Spotify mini bar + desktop Miniplayer, Speechify, ElevenLabs
Reader, macOS Now Playing / MPRemoteCommandCenter, Sleeve/Tuneful, Watch/CarPlay.

Converged conventions:
- **No Stop button exists in modern audio UIs.** Play/pause is one toggle;
  pause always retains position. "Stop" is expressed as dismissing the player
  (Telegram's ✕: stops audio, closes bar, message remains).
- **Control density scales with surface size** in a fixed precedence order:
  smallest = play/pause + hairline progress; then + skip back/forward; then +
  speed chip / queue badge; scrubber only in the expanded view. (Spotify bar →
  Miniplayer → full player; Watch/CarPlay drop the scrubber entirely.)
- **No scrubber on tiny surfaces** — progress is a thin non-interactive line
  or a position readout; seeking is done via skips.
- **Speed on micro-surfaces is a cycling chip**, not a slider: tap cycles
  1x → 1.5x → 2x (WhatsApp, Telegram), label always shows current value.
  TTS apps prove wider ranges are tolerated (Speechify to 4.5x, ElevenLabs
  4x) — don't cap the expanded control at 2x.
- **Asymmetric timed skips** are the podcast norm (back 10–15 s "replay what
  I missed", forward 30–45 s) — but for text-backed TTS the semantic
  equivalent is **skip by sentence** (Speechify), which VF can do *exactly*
  since AgentReplySpeaker already chunks at sentence boundaries. Audible adds
  the two-unit rule: chapter jumps (= next/prev message) over timed jumps
  (= next/prev sentence).
- **Spoken-audio apps remap coarse "next/prev track" inputs** (media keys,
  AirPods, car) to their small seeks via MPRemoteCommandCenter
  skipForward/skipBackward — never track-jump (Overcast pioneered).
  Registering as the macOS Now Playing app gets media keys + AirPods +
  Control Center for free.
- **Per-item resume is universal**; consecutive short items auto-advance
  chronologically after one play press with a soft tone between and a distinct
  end tone (WhatsApp consecutive voice notes).
- **Tapping the mini player's label/body never toggles playback** — it expands
  to the source/full player.

## 2 · Consumed-on-read semantics

Products: Gmail, Superhuman, Slack, Telegram/WhatsApp/iMessage, IG/Snapchat
Stories, Pocket Casts/Apple Podcasts, YouTube, macOS/iOS Notification Center.

Converged conventions:
- **Two orthogonal axes, never conflated**: seen/unseen (attention) and
  kept/archived (location). Consuming NEVER deletes; every product keeps a
  browsable archive. Notification Center (destroys on clear) is the
  acknowledged anti-pattern.
- **Consumption trigger = content actually displayed/played**, not delivered,
  not app-foregrounded. Strictest, most trusted: Telegram's viewport rule
  (rendered on a visible focused surface). Audio/video: playback position.
- **Three-state for temporal content**: unconsumed / in-progress (progress +
  remaining + resume) / consumed at finish. YouTube adds: >~95% heard →
  restart from 0 on revisit, treat as fully consumed.
- **Badge language is two-tier** (Slack): bold/colored = some unread;
  red/pulsing reserved ONLY for directly-addressed items (DMs, mentions —
  for VF: blocking asks). Pulsing for any unread over-alarms.
  → This is a behavior change to today's `setUnreadIndicator` (pulses for
  everything).
- **Stories grammar** for the picker: colored ring = unseen; after full view
  the ring goes static grey but the dot STAYS selectable; partial view keeps
  the ring and resumes at first unseen segment.
- **Manual override in both directions**, hotkey-reachable: mark-read without
  reading (Slack Esc / Shift+Esc all) and mark-unread after (Gmail Shift+U) —
  always local-only, never revokes a delivered receipt.
- **New activity resurrects a consumed container** (reply un-archives the
  thread; new push must re-light a seen/closed session).

## 3 · Chronological browsing of consumed items

Products: iPhone Visual Voicemail, iOS Notification Center, Android
Notification History, Phone Recents, Slack history + jump-to-date,
Telegram/WhatsApp chat lists, Gmail All Mail, Pocket Casts Listening History,
browser history.

Converged conventions:
- **Newest-first for lists; oldest-first inside transcripts.** Two-level
  recency everywhere there are senders: list ordered by each conversation's
  newest item; full chronological transcript within.
- **Consumption changes a marker, never the position** (voicemail dot
  disappears, Gmail bold→regular, podcasts grey-out in place with progress
  bar retained). Removal-on-read is the least-trusted model.
- **Unread boundary drawn inside the history** (Slack "New messages" line),
  not a separate unread screen.
- **Timestamp degradation ladder**: time today → "Yesterday" → weekday →
  date. Day headers once the list spans days; jump-to-date once it gets long.
- **Consecutive same-source items coalesce** into one row with "(N)".
- **Three escalating verbs**: read/listen (flips marker) → archive/dismiss
  (leaves working set, stays in the everything-store) → delete (recoverable
  bin). No product hard-deletes on first action.
- The shade/log split (Android): pill stack = the mutable shade,
  messages.json = the untouchable append-only log. VF already has this shape.

## 4 · Hotkey-only navigation

Products: Cmd-Tab, Slack, Gmail, Superhuman, AirPods/Bose press grammar,
macOS media keys, VoiceOver, tmux/vim, Raycast/Alfred, Todoist.

Converged conventions:
- **Play/pause is one toggle key, never two.**
- **Press-count grammar** (strongest cross-vendor convergence found):
  1 = play/pause, 2 = next/forward, 3 = previous/back, hold = alternate.
- **Transport keys are global** and act on whatever is playing regardless of
  focus.
- **Number keys are positional and stable, never MRU-reordered** (tmux 0-9,
  Cmd+1-9 in browsers/Slack); MRU access is a separate *last-item toggle*
  (tmux prefix+l, vim Ctrl-^) — in practice the highest-frequency switch.
- **Next-UNREAD walk is a dedicated axis** separate from next-item
  (Slack ⌥⇧↓ vs ⌥↓).
- **Act-and-auto-advance** (Superhuman): consuming an item immediately
  presents the next one; undo (Z) instead of confirmations.
- **Esc de-escalates and marks-read, never destroys** (Slack); launchers
  close on Esc with focus restored.
- **Say-all pairs with a single cheap interrupt key** (VoiceOver: plain
  Control pauses speech); skip granularity is a settable unit — sentence
  within item, item within list (rotor thinking).
- **Shortcuts are taught inline at point of use** (Superhuman shows the key
  next to the action) — for VF: chord labels inside the grown pill.

## 5 · Live "what is being read" + cleaned speech with recoverable original

Products: Spotify lyrics, Apple Music Sing, Apple Podcasts transcripts, Kindle
/ Audible Read & Listen (relaunched 2026-02), Voice Dream Reader, Speechify,
Edge Read Aloud + Immersive Reader, Apple Live Captions, Netflix/BBC caption
specs, teleprompters, Apple Intelligence notification summaries, Google
Translate transcribe, screen readers + alt-text, Overcast Smart Speed,
Android Reading Mode.

Converged conventions:
- **Highlight granularity is capability-gated**: word-level only when you own
  synthesis/alignment (Kindle, Edge); without word timestamps, sentence/line
  highlight reads as intentional and complete (Spotify). Never estimate word
  timing — drift reads as broken. VF's sentence-chunked TTS makes sentence
  highlight exactly synchronized for free.
- **Seek unit coarser than highlight unit** (Apple Podcasts highlights words,
  seeks by paragraph).
- **Fixed focal position; the TEXT scrolls** (teleprompter cue line, Voice
  Dream Focused Reading Mode). Show next sentence dimmed below — the one-line
  eye-lead is what makes following feel calm.
- **Temporal depth-of-field**: spoken = dim, current = brightest, next =
  muted; ~3 units visible.
- **Caption sizing math** (Netflix/BBC): ~37–42 chars/line, 2 bright lines,
  17–20 chars/sec ceiling, ≥1 s dwell, clause-boundary breaks.
- **Selecting a text unit repositions playback — the live text IS the
  scrubber** (Spotify, Apple Music, Apple Podcasts).
- **Machine-transformed text is marked in-stream with a light consistent
  style** — Apple Intelligence italics+glyph (= machine-rewritten, tap for
  original), Live Captions underline (= approximate span) — and the verbatim
  original is one gesture away. Transformation is a derived VIEW; the stored
  original is never modified. (Architecture rule for VF-43 integration.)
- **Speech substitution follows the 30-year screen-reader contract**: speak
  role + short description ("link: pricing docs"), never raw characters;
  code is summarized, not read; the substitution is silent in AUDIO and
  accounted for in UI (Overcast Smart Speed's aggregate counter — never
  speak meta-commentary about the cleaning).

## Contradictions the combined design must resolve (critic pass)

1. **Picker ordering**: stable numbers (tmux/Cmd+1-9) vs recency-sorted dots
   (chat lists). Evidence favors stable numbers + a last-session toggle chord.
2. **Consumed position**: Stories re-sort seen items back vs "marker changes,
   position never" (voicemail/Gmail). Resolve per surface: picker may
   de-prioritize, panel history never moves rows.
3. **Stop**: the ticket asks for stop; the convention is stop-as-dismiss
   (Telegram ✕). One glyph must not mean stop-playback AND dismiss-stack AND
   close-and-keep simultaneously.
4. **Esc**: Slack (mark-read) vs launcher (cancel, no state change) vs VF's
   existing panic-button role. One meaning per pill state must be defined.
5. **Display vs playback order**: stack renders newest-bright (list mode) but
   playback consumes oldest-first (transcript mode) — the grown view must
   flip to transcript order when entering playback.
6. **Ring grammar**: two-tier signal (static = unread, pulse = ask only)
   changes today's pulse-for-any-unread behavior.
7. **Now Playing registration**: free media keys/AirPods vs hijacking the
   music the user has playing. Ship as an option.
8. **Skip units**: timed skips (podcast) vs sentence skips (TTS). VF owns the
   text — sentence-within-message / message-within-stack, drop timed skips.

## Genuinely ungrounded — needs Safet's call (no product precedent)

1. **Consumed-by-listening threshold for text**: messengers say any
   substantial playback consumes; podcasts say finish (~95%) consumes and
   early marking is a bug. Recommendation: podcast rule + in-progress resume.
2. **Momentary display**: does growing a stack consume all of it
   (iMessage whole-thread) or only pushes actually rendered (Telegram
   viewport)? Recommendation: rendered-consumes.
3. **Blocking asks under consumption**: no product has a notification that is
   also a blocking question. Recommendation: asks are NEVER consumed by
   read/listen — they stay hot until answered (preserves current semantics).
4. **Cross-session auto-advance**: when a session's stack finishes playing,
   continue into the next unread session? Zero precedent anywhere.
   Recommendation: no auto-advance by default; end tone + "next: <name> —
   ⌃⌥N" receipt.
5. **Global focus-free triage chords**: no product does j/k/e triage via
   system-wide hotkeys. The chord vocabulary (how many chords Safet
   tolerates) must be designed with him.
6. **Per-span "spoken as…" reveal**: novel composition — every ingredient has
   precedent (italic+glyph mark, underline for approximate, role+description
   speech, show-original toggle) but no product combines them per-span.
7. **Six-slot aging**: how consumed sessions age out of ⌃⌥1–6 when a 7th
   session arrives; numbers stay stable meanwhile.
8. **Agent-facing read receipts over MCP**: no convention for telling an
   automated sender its report was seen/heard. Recommendation: consumption
   stays strictly user-local (delivered ≠ seen stays one-way).
