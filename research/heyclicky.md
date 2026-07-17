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

**Adopt:**
1. **Onboarding that demonstrates itself.** Voice Flow has no first-run experience; theirs is the single most-praised thing. A 3-minute first run where the pill flashes, a dictation lands, an overlay guide draws itself, and a Claude Code session reports in would sell every core loop at once.
2. **Inline point-while-talking.** Their `[POINT:x,y:label]` inline-tag mechanic is trivially portable: let the in-app agent (and MCP agents) embed annotation tags in *streamed* replies so arrows/circles appear synchronized with speech, instead of overlay calls arriving as separate tool calls after the fact. The synchronized talk+point is the demo-able magic moment.
3. **Demo-video-first distribution.** The only acquisition channel that verifiably worked for them and it cost $0: short screen recordings of one real magic moment (talk-hotkey → agent answers → overlay points). Post to X + IG Reels. Voice Flow's session-capture + watcher could literally record its own demo material.
4. **Own "local" loudly.** Their users beg for local models; HeyClicky is structurally cloud (AssemblyAI/ElevenLabs/proxy). Voice Flow's STT is local and the watcher never leaves disk — that's the privacy counter-position, and it should be stated as plainly as their "screenshots are never stored."
5. **Value-metric pricing** (if ever monetized): unlimited talk/dictation, meter the agent actions.

**Avoid / validate against:**
6. **Ambient tracking needs visible consent surfaces.** Even HeyClicky is "debating removing" their app/tab tracking under user pressure. Voice Flow's watcher goes far beyond that — the existing kill switches/visibility (menu bar, pill ring, Settings tab) are the right call; never let it become invisible.
7. **Don't chase their consumer-agent platform.** Gmail/Notion voice agents for consumers is their funded lane. Voice Flow's uncontested lane (per the July market research) is the **voice HITL layer for real coding agents** — HeyClicky has nothing pointed at Claude Code / terminal-agent workflows.
8. **Dictation confirms commoditized**: they give it away nearly unlimited on the free tier. It's table stakes, not a selling point.

**Where to find users (the ticket's last question):**
- Their audience (creative-tool learners, students) is reachable but contested. Voice Flow's natural, uncontested audience is **Claude Code / agent power users**: X build-in-public + AI-dev circles, r/ClaudeAI and r/macapps, Claude/dev Discords. The message that lands there: "your agents can talk to you, show you, and wait for you — locally."
- Format matters more than venue: a single genuine magic-moment screen recording outperformed all their other marketing combined. Open-sourcing a piece (as they did) is the credibility multiplier if distribution ever stalls.

**Threat watch**: funded ($10M), YC, shipping fast, moving into hands-free Mac *control* and Windows. If they add a "talk to your coding agent" story, the overlap with Voice Flow's lane becomes direct. Their open-source repo is worth tracking (github.com/farzaa/clicky) — it previews their mechanics.
