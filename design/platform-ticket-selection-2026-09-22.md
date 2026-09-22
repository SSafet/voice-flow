# VoiceFlow ticket selection for the unified platform

Decision owner: Codex. Reviewed 22 September 2026 against Safet's September 18–22 direction and all 68 tickets on the VoiceFlow board (26 open/review, 42 Done). Ticket bodies, comments and five attached screenshots were fetched. Done is the board's acceptance state, not independent proof that every historical implementation remains correct. The original records remain in Notion; this document is the implementation selection and the worked example for VF-75.

## What we are optimizing

1. A usable thread across Mac, browser and phone, with the work running where its files live.
2. Reliable voice, captured data and structured annotations feeding that thread.
3. Compact, readable controls; explicit progress, refusal, recovery and completion.
4. Preserve accepted daily behavior and local data while replacing the panel, local-network sync and duplicate stores.
5. Reuse existing implementations and maintained software. OpenCode 2.0.12 is the migration target; model allocation is at Codex's discretion.

## Work selection and batching rule (VF-75)

Investigate before assigning a batch. For each candidate record the user outcome, actual files/components it changes, shared contracts, required evidence, and whether its old implementation survives the new platform. A title or architectural guess is not enough to establish independence.

- **Parallel:** independent file ownership and contracts, with validation that can run independently. Use separate branches/worktrees and isolated databases, runtime roots and ports.
- **One batch:** one coherent user flow or shared invariant, with overlapping implementation or the same expensive test environment. Give that batch one owner and one integration review; retain a check for each ticket's outcome.
- **Sequence:** contract producer before consumer, competing edits to the same files, migration dependencies, or tests that mutate the same installed app/device/global settings. Rebase and review against the integrated code before claiming success.
- **Re-evaluate scope when investigation finds overlap.** Transfer ownership or serialize the shared portion; do not allow two agents to fix the same component independently.
- **Evidence follows the claim:** deterministic tests for rules, real transport/database tests for boundaries, rendered UI at desktop and phone widths, signed isolated-app/device checks for native behavior, and a real model turn for model integration. Passing a test that only reads configuration does not prove the runtime used it.
- **Delivery state is explicit:** designed, implemented, reviewed, integrated, validated, deployed, and user accepted are different facts. Only start tickets actually being worked on; move completed work to Waiting on Safet with concise evidence. Safet owns Done.

### Applied to the current work

| Batch | Ownership and dependency | Validation |
|---|---|---|
| Thread-record integrity | Database migration + trigger fixtures; parallel with UI and runtime because files are disjoint | Real Postgres migration and refusal tests; gateway thread/trigger suites |
| Shared thread screens | W5 web screens, sign-in route, endpoint selection, drafts, answer trays and activity; one owner | Screen tests, typecheck, desktop/phone browser evidence; integrated send/stop/reload/queue walk |
| OpenCode v2 on Atika | Runtime supervisor/adapter, private MCP/model bridge, binary installer and image pins | Exact pinned binary, fake provider+MCP, cancellation/resume/limits, real OpenRouter turn |
| OpenCode v2 on VoiceFlow | Swift HTTP/events, isolated runtime configuration, native plugin tools, binary/SDK assets and updater | Exact pinned binary, native tool loading, supervised process exit, Swift tests; isolated signed app |
| Mac platform foundations | Review/integrate V1 thread store, V3 runtime launcher and L1M identity after their shared contracts and v2 decisions stabilize | Store transaction tests, actual runtime launch, auth/reconnect/restore; no daily-app mutation |
| Captures, annotations, current focus | S1/S2/S3/S4 plus VF-6 and VF-70; integrate stores first, then native/shell/UI consumers | Search returns actual captured records; marks preserve geometry/context; current focus updates on next turn |
| Phone parity | Shared UI + device transport + local records, then VF-30 | Offline persistence, automatic background delivery/retry, Mac-online and Mac-offline journeys, authorised Notion action |
| Delivery checking | VF-69, VF-74, VF-73 share run/ticket/deployment evidence: one design/owner after lifecycle facts are durable | Complete/incomplete/no-deploy-needed cases, bounded follow-up and no duplicate loop |

Do not batch the entire runtime migration with all Mac UI work: they have different failure boundaries and proof. Do batch the two delivery-check triggers around one checker once the required facts exist. Device tests on the same phone and app installations run sequentially.

## Open tickets: decisions

| Ticket | Decision | Reason and acceptance to carry forward |
|---|---|---|
| VF-6 | Include with annotation integration | Hide marks when their source window/context is absent; retain valid window-relative geometry on movement. Do not pretend a screenshot pixel identifies a live element after scroll/navigation; use verified anchors or invalidate. |
| VF-8 | Include with runtime/settings integration | Model and supported effort controls per runtime, next-turn changes, visible quota/failure; check existing picker code before rebuilding. Codex screen/tool access must be verified with the actual runtime. |
| VF-9 | Defer distribution task | A public demo follows a proven daily-use flow. Posting remains Safet's action. |
| VF-10 | Include truthful privacy explanation at settings/cutover | Older claims about all data staying local are inaccurate for cloud threads and attachments. Describe actual storage, model calls, capture policy and grants; no blanket local-only claim. |
| VF-11 | Defer open-source/distribution decision | Does not unblock the personal platform. |
| VF-12 | Include essential setup; defer scripted showcase | Permission status, runtime availability and first thread must work. The old three-minute panel demo points at UI being removed. |
| VF-13 | Defer synchronization enhancement | First make structured marks, speech and thread delivery reliable. Later synchronize typed annotation events with output; do not add a second unvalidated inline-tag protocol now. |
| VF-14 | Preserve as principle | Maintain dictation reliability and invest in what voice feeds. It is not an implementation ticket; Safet retains acceptance. |
| VF-30 | Include with phone parity | The later cross-device platform request supersedes the July mobile-work pause. Phone can query permitted VoiceFlow data and perform a requested Notion action; unavailable Mac data must be explained. Reuse Atika connectors. |
| VF-31 | Defer workflow automation | Keep source URL + extraction intent available in captures and reuse the existing knowledge workflow; do not hardcode a separate YouTube daemon into the platform migration. |
| VF-32 | Defer calendar scheduling workflow | Depends on stable connectors, current tasks and triggers. Retain explicit confirmation before changing the calendar. |
| VF-34 | Preserve implemented behavior in Today.md | Timestamped current-day instructions, replacement and stale-context handling must survive. Do not carry a second FOCUS-NOW store alongside Today.md. Existing completion awaits Safet. |
| VF-35 | Include existing-data indexing and safe retention; defer collection expansion | Existing capture/dictation/watcher files become searchable through one store. Earlier screenshot and watcher-containment repairs are already separate Done tickets. The old source scheduler plan conflicts with the later decision to remove Data Sources. No new raw keystroke collection or vision egress is implied. |
| VF-36 | Preserve research, defer monitoring feature | Research deliverable awaits Safet. Phone distraction control adds permissions and a separate product flow; it does not unblock parity. |
| VF-50 | Include compatibility assessment in external-session bridge | The 2026-07-28 spec really removes transport sessions. Stable app-owned external-thread handles must not rely on Mcp-Session-Id. Verify current Codex/Claude/OpenCode client behavior and support both required versions; avoid a speculative full protocol rewrite before a client compatibility test. |
| VF-54 | Preserve and integrate existing continuity behavior | Configurable routing model/instructions, provider fallback and visible failure must survive; a voice follow-up cannot attach to the most recent background automation. Existing work awaits Safet. |
| VF-57 | Defer metrics product | Reliable timestamps/read/listen progress should remain available, but daily quality scoring and a dashboard need separate definitions. Do not invent actual work output from token/word counts. |
| VF-62 | Preserve manual control when moving to Today.md | Existing add/remove/reorder and stale-edit protection are requirements. A plain file migration cannot silently remove the useful editing flow. Existing work awaits Safet. |
| VF-68 | Defer ambient wake-word feature | A new microphone owner/lifecycle and real pronunciation/battery validation would complicate the migration. Keep current hotkey and transcribed wake-name behavior. |
| VF-69 | Include after durable completion evidence | One bounded checker compares required delivery with observed commits, tests, evidence and deploys; follow up only on missing authorised work. No blanket auto-deploy rule. |
| VF-70 | Include with Today.md | User-owned current focus reaches subsequent turns, with empty and stale states explicit. Preserve focus as context, not authorisation or a reason to invent work. |
| VF-71 | Preserve automatic delivery/recovery through new channel | Existing fix was installed and physically tested; final user QA remains. Transport changes to Atika, but capture-triggered delivery, closed-app behavior, outage recovery and data preservation remain acceptance cases. |
| VF-72 | No implementation | Empty title, body and comments; no requirement to infer. |
| VF-73 | Keep as later integration outcome | An agent helps manage delegated work. First establish complete thread/run/approval/delivery facts, then compose the oversight flow; the one-line ticket does not authorise an unlimited autonomous manager. |
| VF-74 | Include with VF-69 checker after lifecycle integration | A Waiting → Done transition requests a deployment assessment. Report deployed, pending or unnecessary; ticket acceptance is not itself permission to deploy. |
| VF-75 | Implemented by this document | Selection/batching criteria plus this worked application. No automated scheduler was requested. |

## Accepted tickets: preservation map

These 42 tickets remain Done. Their original layouts, transport mechanisms and historical implementation claims are not immutable requirements. Preserve the underlying accepted behavior and repeat the relevant checks in the replacement. VF-53 explicitly records an abandoned approach, so do not resurrect it merely because it is Done.

### Input and native behavior

- [VF-3](https://app.notion.com/p/Dictations-that-are-directly-recorded-only-to-VoiceFlow-not-pasted-39f6a7d4954e808fbe39d8fcf7265158) — Dictations that are directly recorded only to VoiceFlow, not pasted
- [VF-5](https://app.notion.com/p/introduce-keyword-to-wake-the-assistant-39f6a7d4954e80d6bd70c32b4b388951) — introduce keyword to wake the assistant
- [VF-20](https://app.notion.com/p/Mobile-polish-Mac-app-icon-side-key-dictate-launch-voice-reactive-record-animation-3a26a7d4954e81358bedee5540948319) — Mobile polish: Mac app icon, side-key dictate launch, voice-reactive record animation
- [VF-23](https://app.notion.com/p/Fix-capabilities-only-working-for-sessions-3a26a7d4954e804a8ed4c63c77a8aca8) — Fix capabilities only working for sessions
- [VF-24](https://app.notion.com/p/Microphone-to-be-updated-if-a-selected-one-is-disconnected-3a26a7d4954e80eba29adaa81dfef8e0) — Microphone to be updated if a selected one is disconnected
- [VF-37](https://app.notion.com/p/Dictation-processing-state-dates-shared-cursor-clean-intake-3a56a7d4954e81fcb40dc37991ab870d) — Dictation processing state: dates, shared cursor, clean intake
- [VF-39](https://app.notion.com/p/Merge-continuation-dictations-into-one-intake-item-3a56a7d4954e81079169d9c2986b7ed6) — Merge continuation dictations into one intake item
- [VF-40](https://app.notion.com/p/I-can-t-answer-to-the-assistant-with-opened-notification-after-it-s-responded-and-can-t-open-the-pan-3a56a7d4954e807792c6d41a7ea51944) — I can’t answer to the assistant with opened notification after it’s responded and can’t open the panel at all by clicking the expanded pill
- [VF-43](https://app.notion.com/p/Sanitize-agent-output-before-reading-it-aloud-3a96a7d4954e8196b7c9d562acd101d1) — Sanitize agent output before reading it aloud
- [VF-44](https://app.notion.com/p/Prevent-toggle-dictate-stop-race-from-destroying-audio-3a96a7d4954e81ddb672f93872605fcb) — Prevent toggle-dictate stop race from destroying audio
- [VF-51](https://app.notion.com/p/Android-always-on-overlay-bubble-dictation-with-direct-text-insertion-3ac6a7d4954e8176a341c248dd76c5a6) — Android: always-on overlay bubble dictation with direct text insertion
- [VF-55](https://app.notion.com/p/Synchronizing-the-phone-s-history-with-the-voice-flow-which-is-on-the-PC-should-review-the-notes-and-3af6a7d4954e80f9bea8e9ab99b1d265) — Synchronizing the phone's history with the voice flow which is on the PC should review the notes and if something is for FLORA, we should trigger the assistant.
- [VF-56](https://app.notion.com/p/Voiceflow-s-setting-for-setting-the-speed-of-the-speech-of-the-agent-in-the-settings-doesn-t-get-upd-3af6a7d4954e80eaab98faaba8b2ecc3) — Voiceflow's setting for setting the speed of the speech of the agent in the settings doesn't get updated when I actually trigger it. Also, it needs to stay persistent after I change it with the buttons from the expanded pill.
- [VF-61](https://app.notion.com/p/FLORA-wake-word-trigger-attaches-to-last-run-assistant-even-if-it-s-an-automation-3b36a7d4954e8092bfadeeabed03addb) — FLORA wake word trigger attaches to last run assistant even if it’s an automation
- [VF-65](https://app.notion.com/p/Release-focus-to-other-apps-on-the-first-click-outside-Voice-Flow-3d26a7d4954e81ceb3cae40ff7a09dcf) — Release focus to other apps on the first click outside Voice Flow
- [VF-66](https://app.notion.com/p/Keep-workspace-within-the-display-when-search-results-contain-long-text-3d26a7d4954e81b6b050f7b4dd5a3fcd) — Keep workspace within the display when search results contain long text
- [VF-67](https://app.notion.com/p/Annotation-overlay-shapes-highlighter-number-stamps-six-colours-one-size-dial-and-keyboard-con-3d36a7d4954e8168b9ddf2a1d1cfb88d) — Annotation overlay: shapes, highlighter, number stamps, six colours, one size dial, and keyboard control

### Thread persistence and consumption

- [VF-15](https://app.notion.com/p/There-are-stale-sessions-being-created-3a06a7d4954e80c7bc27d480fe34857f) — There are stale sessions being created
- [VF-16](https://app.notion.com/p/ChatPanel-redesign-two-content-surfaces-instead-of-five-feature-tabs-3a06a7d4954e8179a9bed13558104916) — ChatPanel redesign: two content surfaces instead of five feature tabs
- [VF-17](https://app.notion.com/p/Read-aloud-starts-from-the-consumption-cursor-not-the-top-3a16a7d4954e81d5b44dd2b680865869) — Read-aloud starts from the consumption cursor, not the top
- [VF-18](https://app.notion.com/p/Agent-notifications-are-being-removed-from-agents-panel-after-I-click-delete-from-the-notification-p-3a16a7d4954e806a8b94d9c9063985e1) — Agent notifications are being removed from agents panel after I click delete from the notification part, and not kept in agents panel.
- [VF-21](https://app.notion.com/p/The-agents-are-accumulating-background-tasks-of-listen-without-replacing-them-The-agent-should-have-3a26a7d4954e8018b551d6f11f2401f8) — The agents are accumulating background tasks of listen without replacing them. The agent should have only one listen, which is the latest thing, because we don't have a way to answer to different ones.
- [VF-22](https://app.notion.com/p/Listening-to-a-completed-session-s-stack-removes-it-from-the-pill-while-audio-still-plays-3a26a7d4954e812aa0cdc8b52e4599d7) — Listening to a completed session's stack removes it from the pill while audio still plays
- [VF-27](https://app.notion.com/p/Persist-and-resume-selectable-Assistant-sessions-3a26a7d4954e81f1a04afedf45ef2845) — Persist and resume selectable Assistant sessions
- [VF-28](https://app.notion.com/p/Persist-and-switch-between-Assistant-conversations-3a26a7d4954e81328642ec5e9a80bf2e) — Persist and switch between Assistant conversations
- [VF-48](https://app.notion.com/p/Session-player-consumable-notifications-session-tracking-ergonomics-redesign-3ab6a7d4954e81babbc3db796a6f8be1) — Session player + consumable notifications: session-tracking ergonomics redesign
- [VF-53](https://app.notion.com/p/Receiving-multiple-session-updates-in-Voiceflow-and-me-triggering-the-listening-of-the-sessions-it--3af6a7d4954e801481ebfdd1743a8259) — Receiving multiple session updates in Voiceflow and me triggering the listening of the sessions, it's always starting from the beginning. I want it to start from the latest one.
- [VF-63](https://app.notion.com/p/One-composer-component-auto-growing-multi-line-input-with-image-paste-3b46a7d4954e81cbad42f7d7e27e5d1a) — One composer component: auto-growing multi-line input with image paste
- [VF-64](https://app.notion.com/p/Redesign-the-main-panel-around-connected-data-sources-and-agent-workflows-3d16a7d4954e8159b850ce91e9701a12) — Redesign the main panel around connected data sources and agent workflows

### Runtime, persona and containment

- [VF-4](https://app.notion.com/p/Use-codex-oauth-to-utilize-the-subscription-and-use-it-as-the-assistant-39f6a7d4954e8027af00c7f63365cbf1) — Use codex oauth to utilize the subscription and use it as the assistant
- [VF-26](https://app.notion.com/p/Decide-wire-a-Claude-Code-Stop-hook-or-declare-it-superseded-by-the-Voice-Flow-listener-3a26a7d4954e816a9256c147f2d79dd6) — Decide: wire a Claude Code Stop hook, or declare it superseded by the Voice Flow listener
- [VF-29](https://app.notion.com/p/Codex-assistant-doesn-t-have-enough-access-3a26a7d4954e808ab16fcf8729d5fbd2) — Codex assistant doesn’t have enough access
- [VF-49](https://app.notion.com/p/Persistent-agents-named-specialist-assistants-with-own-tools-context-and-data-sources-3ab6a7d4954e8160a975dde8f606e954) — Persistent agents: named specialist assistants with own tools, context, and data sources
- [VF-59](https://app.notion.com/p/Contain-the-assistant-with-an-OS-enforced-sandbox-3b16a7d4954e81ee8ec7e45fd3ee639b) — Contain the assistant with an OS-enforced sandbox
- [VF-60](https://app.notion.com/p/Leaked-OpenCode-runtimes-survive-app-restarts-3b36a7d4954e81b784d4ea48c1e2d7b4) — Leaked OpenCode runtimes survive app restarts

### Phone delivery and onboarding

- [VF-7](https://app.notion.com/p/Lightweight-mobile-application-that-would-enable-me-to-dictate-and-use-hotkeys-from-my-phone-and-als-3a06a7d4954e8077ace2d6c2327ef419) — Lightweight mobile application that would enable me to dictate and use hotkeys from my phone and also be able to access the Voiceflow's assistant.
- [VF-19](https://app.notion.com/p/Get-the-mobile-app-onto-Safet-s-phone-install-Tailscale-cleanup-QA-3a16a7d4954e819c8483dacce6133afe) — Get the mobile app onto Safet's phone: install, Tailscale, cleanup, QA

### Watcher and knowledge foundations

- [VF-1](https://app.notion.com/p/Competitor-research-HeyClicky-39f6a7d4954e80ecbbded2fc33a898b0) — Competitor research HeyClicky
- [VF-38](https://app.notion.com/p/Todos-and-Logs-landing-zone-in-Notion-for-dictated-items-3a56a7d4954e817f8e6afb3193da8391) — Todos and Logs landing zone in Notion for dictated items
- [VF-42](https://app.notion.com/p/Research-Claude-Code-s-record-feature-3a96a7d4954e804592bccf5c6654ee22) — Research Claude Code’s record feature
- [VF-45](https://app.notion.com/p/Watcher-capture-defects-Retina-compress-no-op-half-res-display-permanent-stall-latch-3aa6a7d4954e81b4be28d23d6179eade) — Watcher capture defects: Retina compress no-op, half-res display, permanent stall latch
- [VF-46](https://app.notion.com/p/Harden-the-nightly-watcher-review-scope-its-tool-grants-sandbox-it-mark-day-folder-data-as-untrus-3aa6a7d4954e816fbaa7cc05327f8b1e) — Harden the nightly watcher review: scope its tool grants, sandbox it, mark day-folder data as untrusted

## Proof and limits

Board snapshot: 68 total, 5 Waiting on Safet, 1 Next, 20 Inbox, 42 Done at review time. All pages and comment collections were read through the paginating Tickets CLI. Five attached images on VF-23, VF-24, VF-40 and VF-61 were inspected. The only status changed for this analysis is VF-75; other tickets are not presented as newly completed. Selection is a design decision, not proof that the selected product work has shipped.

Sources: [VoiceFlow board](https://app.notion.com/p/39f6a7d4954e815aa6c2c3059a3b097a), Atika `docs/architecture/platform/00-governing-design.md`, the platform master plan and current handoff, [OpenCode v2 migration](https://opencode.ai/v2/docs/migrate-v1), [MCP 2026-07-28 changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog). Runtime/provider and client version claims must be rechecked when their implementation begins.
