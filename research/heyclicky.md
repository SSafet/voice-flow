# Competitor research: HeyClicky (ticket #1)

*Researched 2026-07-17. Sources: heyclicky.com, github.com/farzaa/clicky (the open-source MIT version), Product Hunt, YC company page, DailyDropout profile, XDA hands-on review, explainx demo breakdown, X testimonials.*

## Snapshot

- **What**: "an ai buddy that lives on your mac" — a small animated character next to the cursor. Hotkey → sees the screen, hears your voice, answers out loud, points at UI elements, draws on screen. Say "heyclicky agent" → background agent (research, Notion/Gmail/Calendar tasks, even building small Mac apps).
- **Who**: Farza Majeed (ex-Buildspace founder, 125k-builder community, wound down 2024). Started as a weekend side project Jan 2026, open-sourced, went viral, YC Spring 2026, reportedly ~$10.1M raised. Claims **25,000+ users** on the site.
- **Pricing**: Free = 25 talk + 25 agent messages/mo. Pro $20 = unlimited talk + dictation, 150 agent messages. Max $100 = 1,000 agent messages. Dictation is effectively free/unlimited everywhere. Builder + student discounts.
- **Platform**: macOS (Catalina+), Windows waitlisted.

## 1. How it actually works (the ticket's first question)

**Yes — at its core it is the "basic form": hotkey → screenshot + voice → LLM → spoken answer.** The open-source repo (7.1k stars, MIT, 95% Swift) shows the whole pipeline:

- **Context**: ScreenCaptureKit full-screen screenshot captured at hotkey press (Ctrl+Option, push-to-talk). No deeper app introspection for the answer itself. "Works with anything on your screen, no plugins" — because it's just pixels + vision model.
- **Voice**: mic audio streamed over WebSocket to AssemblyAI for live STT.
- **Reasoning**: Claude (Anthropic). Streaming replies.
- **Speech out**: ElevenLabs TTS.
- **Keys**: proxied through a Cloudflare Worker so the client never holds API keys.
- **The "pointing" trick**: Claude embeds `[POINT:x,y:label:screenN]` tags inline in its streamed response; a transparent NSPanel overlay animates the buddy/cursor to those coordinates while it talks. That's the entire "it points at the button" magic — cheap, inline, very effective on video.
- **The one ambient piece**: always-on **text-only accessibility tracking** (app names, tab titles) so it can nudge you when doom-scrolling. Their own FAQ: "it's the one thing that comes closest to watching you, and we're debating removing it."
- **Agents**: the commercial (closed) layer — voice-spawned background agents with Gmail/Notion/Calendar integrations; this is the metered, monetized unit.
- **New direction** (the May 30 viral demo, ~3M views, praised by Greg Brockman): always-on listening, **GPT-Realtime 2.0 speech-to-speech**, no wake word, and actual Mac control (open apps, edit code) via AppleScript + Accessibility APIs. They're moving from *guidance* to *hands-free control*.

**Read**: architecture is close to Voice Flow's (native Swift, NSPanel overlays, hotkey capture, streaming TTS) but cloud-tied (AssemblyAI + ElevenLabs + Claude via their proxy). Voice Flow's local STT and on-device watcher are genuine differentiators they can't claim.

## 2. How they found users (the ticket's second question)

**The honest answer: audience-as-distribution.** This channel is not copyable, but its mechanics are:

1. **Founder's existing audience** — Buildspace gave Farza millions of followers who were waiting for his next thing. One tweet = launch.
2. **Demo-video-first marketing** — short screen recordings of real "magic moments" (voice-controlling a Mac hands-free, learning DaVinci Resolve live). The 104-second May 30 video hit ~3M views. Zero ad spend anywhere in the record.
3. **Open source as credibility engine** — MIT repo (6–7k stars) let devs read the internals, fork it (community "openclicky" forks exist), and vouch for it. Tech press (XDA, Yahoo Tech) covered it *because* it was open.
4. **Elite amplification** — Greg Brockman ("real magic"), Lenny Rachitsky ("my new favorite onboarding experience"), YC partners quote-tweeting demos.
5. **Instagram Reels virality** (per their YC page) — consumer-side reach beyond dev Twitter.
6. Product Hunt was an afterthought: 146 upvotes, #6 of the day, hunted by a third party. **PH was not the channel.**

**Who the users actually are**: people learning complex creative software (DaVinci Resolve, After Effects, Figma, FL Studio, CapCut), students (discount), indie builders (discount). The killer quote from XDA: *"It's the difference between learning about the software and learning inside the software."*

## 3. What customers want (from reviews, PH comments, testimonials)

**Wanted / praised:**
- **Action-taking is the #1 request.** PH comments: "actually take actions on my screen", "is it able to control the mouse? That would elevate the abilities intensively." HeyClicky answered with agents + the hands-free demo. Demand for *do it for me* > *tell me how*.
- **Pointing/drawing while talking** — users explicitly asked for circles/arrows on screen; the animated pointing is the most-shared feature.
- **Learning-inside-the-tool** — the validated wedge use case.
- **Onboarding as a product moment** — "hands down the best onboarding experience": in ~5 minutes it plays a video, *creates a fun website for you, runs a report* — i.e., the agent demonstrates itself instead of a setup wizard. Lenny Rachitsky singled this out.
- Screenshot-to-Claude users recognized it as "the 10x version" of their manual workflow.

**Pushback / fears:**
- **Privacy is the recurring objection**: "constant visibility is the double-edged sword", requests for timed context windows and *local models*. HeyClicky's mitigations (hotkey-gated capture, "screenshots are never stored", delete-everything) are front-and-center on the site — and their always-on accessibility tracking still makes even *them* uncomfortable.
- **Distraction** worry: an animated buddy near the cursor is cute on video, noisy in real work.
- **Platform**: loud Windows/Linux demand; mac-only frustration everywhere.
- New product skepticism: closed commercial build can't be audited, no track record.

## 4. UI/UX read

- **Landing page**: a playful fake-macOS desktop — draggable windows playing .mov demos, kaomoji, "HELLO my name is" stickers, menu-bar cosplay, all-lowercase copy, light theme, manifesto in a Notes window ("it's an interface problem… the ai interface the next billion people will use"). Personality-first, consumer-toy energy; the videos ARE the content.
- **Product**: a character, not a chrome element — it lives beside the cursor, moves, points, talks. Voice-first with spoken replies by default (opposite of Voice Flow's audio-on-demand rule).
- **Pricing UX**: one clean value metric — talk is unlimited once paid, *agent actions* are the metered scarce unit. Easy to understand, maps cost to their real compute cost.
- Distinct from Voice Flow's design language (deliberate minimal pill, dark, quiet). Theirs optimizes for shareability/delight; ours for staying out of the way during real work.

## 5. Takeaways for Voice Flow

Split into the two things they actually teach: **how to demonstrate the product** and **what to change in the product**.

### A. How to demonstrate Voice Flow

1. **One magic-moment screen recording beats everything.** The only acquisition channel that verifiably worked for HeyClicky cost $0: a short (~100 s) screen recording of one genuinely magic moment, posted raw. For Voice Flow that moment is: talk-hotkey → a Claude Code session answers by voice → an overlay draws/points on screen → the user replies by talking. Record real use, not staged marketing — authenticity is what went viral for them.
2. **Distribution venues, in order**: X (build-in-public / AI-dev circles) first, then Instagram Reels (their consumer virality channel), then r/ClaudeAI + r/macapps and dev Discords. No ads — HeyClicky spent nothing. Product Hunt demonstrably didn't matter (146 upvotes); skip the PH-first instinct.
3. **The pitch that lands in the uncontested lane**: "your coding agents can talk to you, show you, and wait for you — locally." Aim at Claude Code / terminal-agent power users, not their creative-tool learner audience (contested, and consumer-shaped).
4. **Say "local" as loudly as they say "never stored".** Their users beg for local models; HeyClicky is structurally cloud (AssemblyAI, ElevenLabs, key proxy). Voice Flow's STT is on-device and the watcher never leaves disk — put that sentence on every surface where the product is described.
5. **Open-source a piece for credibility.** Their MIT repo produced stars, forks, tech-press coverage, and trust ("you can read how it works"). If distribution stalls, open-sourcing a component (e.g. the overlay/annotation layer or the pill) is the multiplier.
6. **Let the product film itself.** Session capture bundles + the watcher already record narrated screen material — demo footage is a byproduct of daily use; harvest it.

### B. What capabilities to change or add

1. **Add: a self-demonstrating first run.** Their onboarding is the single most-praised thing in all feedback ("best onboarding I've had": in ~5 min it plays a video, builds you a website, runs a report — the agent demos itself). Voice Flow has no first-run at all. Build a 3-minute guided first run where the pill flashes a receipt, a dictation lands in a real app, an overlay guide draws itself, and a (bundled or simulated) agent session reports in and asks a question. This is both a capability and the demo engine for A1.
2. **Add: inline point-while-talking.** Their whole pointing magic is `[POINT:x,y:label]` tags embedded in the *streamed* reply, rendered live on the overlay. Port it: let agents embed annotation tags inline in streamed replies so arrows/circles appear synchronized with the spoken/streamed sentence, instead of overlay tool calls landing separately after the fact. Cheap to build on the existing `OverlayManager`, and it's the demo-able moment for A1.
3. **Change (double down, don't add): watcher visibility.** The #1 user fear in their feedback is being watched; even HeyClicky is "debating removing" its always-on app/tab tracking. Voice Flow's watcher goes further than theirs — the existing visibility (menu-bar submenu, amber pill ring, Settings tab, kill switches) is validated; never let recording become invisible, and consider a HeyClicky-style plain-language privacy FAQ in Settings.
4. **Don't add: consumer-agent integrations.** Gmail/Notion/Calendar voice agents for consumers is their funded lane. Voice Flow's answer to the market's #1 request ("actually take actions") is already better for its audience: real Claude Code sessions doing real work, with Voice Flow as the human-in-the-loop layer. Deepen that instead of chasing mouse-control or consumer integrations.
5. **Don't invest in dictation as a differentiator.** They give unlimited dictation away on paid tiers and generous amounts free — it's confirmed table stakes. Keep it excellent, stop expecting it to sell the product.
6. **If ever monetized: meter agent interactions, not talk.** Their pricing (unlimited talk/dictation, metered agent messages) maps price to compute cost and is instantly understood.

**Threat watch**: funded ($10M), YC, shipping fast, moving into hands-free Mac *control* and Windows. If they add a "talk to your coding agent" story, the overlap with Voice Flow's lane becomes direct. Their open-source repo is worth tracking (github.com/farzaa/clicky) — it previews their mechanics.
