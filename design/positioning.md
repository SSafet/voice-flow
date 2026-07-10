# Voice Flow — Positioning

*One-pager, grounded in the verified market research of 2026-07-10 (104-agent deep-research pass + orchestration-tool sweep; sources in the companion landscape page).*

## One-liner

**Voice Flow is the human side of agentic coding** — a macOS menu-bar companion that gives every Claude Code session a voice, a face on your screen, and a way to reach you.

## Positioning statement

For developers running several coding agents in parallel, Voice Flow is the **desktop interaction layer** that lets agents ask, notify, show, and listen — answered by voice, typing, screenshot, or a recorded demonstration — unlike session managers (Conductor, Nimbalyst, CodeLayer) and approval inboxes (gotoHuman, AUQ) that only queue text, and unlike dictation apps (Superwhisper, Wispr Flow) that only push words in.

## The problem

Human attention is the bottleneck of parallel agentic coding, and every existing tool treats it as a text queue:

- Agent questions scatter across terminal windows; sessions stall silently while you look elsewhere.
- Replies come back as walls of text you must stop and read — nothing speaks them to you.
- When words fail, you can't *show* the agent — nothing records a narrated demonstration as context.
- Nothing on the desktop persists: no ambient surface that knows which session is talking, which is waiting, and which you haven't heard yet.

## What we deliberately don't compete on

- **Raw dictation.** Commoditized: Superwhisper ($8.49/mo, local models), VoiceInk ($25 lifetime, open source), Wispr Flow ($15/mo). Context-aware formatting is already table stakes there.
- **Basic voice input to an agent.** Claude Code ships first-party `/voice` (Mar 2026); Superwhisper pipes voice into Claude Code since Apr 2026. Voice-in is a feature, not a product.

## The three pillars (all shipped today)

1. **Voice-first human-in-the-loop for parallel sessions.** Blocking `ask_user` + async `notify_user` + per-session voice routing (⌃⌥1–6) + streaming TTS readback + answers by voice / typing / screenshot / demonstration — behind one persistent pill. No shipped product combines more than one slice: Spokenly = voice ask only; AUQ = terminal inbox only; Omnara = phone chat, no per-session routing; Happy = voice in, TTS readback still an open feature request. Demand is direct: 8+ open claude-code issues ask for spoken readback (#42700, #45251, …); AUQ exists because parallel agents' questions were "scattered across different windows."
2. **Narrated demonstration capture as agent context.** Record screen + voice, hand the timed bundle to the agent. Nobody ships this; the demand is visible next door — claude-video (~7k stars in 2.5 months) ingests *existing* video, and claude-code #12676 asks for video input citing bug-repro recordings.
3. **Proactive workflow review from ambient watching.** Patterns ledger + nightly headless review + suggestions pushed as overlays. Dayflow (6.7k stars) proves capture demand but is retrospective-only; the category incumbent (Rewind/Limitless) is dead — Meta acquired it and disabled capture in Dec 2025.

**Supporting edge:** session-scoped, file-backed agent overlays (step guides, info panels, annotations) — beyond Screen Annotations' basic MCP drawing — and the pill itself: among ~20 surveyed products, none has a persistent macOS desktop presence.

## Watchlist

- **Anthropic** extending `/voice` to TTS readback or notifications would erode pillar 1 — the feature requests are open and first-party.
- **Omnara** (mobile, two-way voice) and **Happy** (voice input, TTS FR #624 open) are converging from the phone side.
- **Screen Annotations** could grow from drawing into guides/panels.

## Product principles that ARE the positioning

One pill, no extra windows. Pushes never take the screen; audio never auto-plays. Unread messages outlive the sessions that sent them. The user routes their voice; agents never grab it.
