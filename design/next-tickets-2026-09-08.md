# Next tickets — 8 September 2026

The pickup snapshot contained VF-34, VF-36, VF-54 and VF-62. VF-36 is a research ticket; the other three change the macOS app. The Android companion was inspected on the connected physical phone without enabling additional monitoring or changing its permissions.

| Ticket | Delivered | Proof |
|---|---|---|
| VF-34 | Shared timestamped `FOCUS-NOW.md`, current/historical handling, replacement on a new focus, per-turn assistant context, Watcher review rule, and Settings → Watcher → Daily context editor | [Live cases](vf34/live/receipt.json), [date/store tests](vf34/unit-validation.txt), [prompt tests](vf34/prompt-validation.txt), [native editor](vf34/daily-context.png), [ticket-only staged-source check](vf34/committed-scope-validation.txt); commit `491be07` |
| VF-36 | Platform feasibility, grant/revocation design, privacy/battery tradeoffs, Android-first recommendation, and local kill-switch contract | [Assessment with official sources](vf36/phone-distraction-controls.md), [physical-device capability inspection](vf36/device-capabilities.json); commit `aa6b4a4` |
| VF-54 | Bounded recovery through the saved Assistant API provider after Codex failure; same editable routing instructions, real diagnostics, and a visible receipt when no provider can decide | [Real provider recovery](vf54/fallback-validation.txt), [routing tests](vf54/unit-validation.txt), [persisted configuration tests](vf54/config-validation.txt); commit `bbfd39e` |
| VF-62 | Basic Add/Remove editor in the main workspace’s Queue sidebar page (also opened by menu bar, pill menu and queue overlay); existing file persistence, live reload, preserved drafts and stale-edit rejection | [Native editor](vf62/queue-editor.png), [button/store tests](vf62/validation.txt); commit `dd824e5` |

The live VF-34 cases use a disposable fixture and the shipping prompt/review rule: a real Codex assistant wrote X, replaced X dated three days earlier with Y, a review adopted Y, and another review rejected stale focus. They do not claim that tonight's scheduled full archive review has already run. VF-54 injects only the Codex failure; its successful fallback uses the actual saved OpenRouter model and credential. No secrets appear in these artifacts.

Focused reproduction:

```sh
./scripts/test-agent-harness.sh --unit --only queue_editor
./scripts/test-agent-harness.sh --unit --only daily_focus
./scripts/test-agent-harness.sh --unit --only agent_prompt
./scripts/test-agent-harness.sh --unit --only assistant_continuity
./scripts/test-agent-harness.sh --unit --only system_agents
```

The **full unit gate passed**: 49 successful suite receipts support 80 registered checks, including release/QA app compilation, workspace UI, clipboard, capture, all three runtimes, queue editing, daily context and provider fallback. [Full log](next-evidence-2026-09-08/unit-gate.txt), [audited evidence](next-evidence-2026-09-08/unit-evidence.json), [execution journal](next-evidence-2026-09-08/execution.jsonl).

This validates the integrated working checkout, including the runtime edits already present at pickup. Ticket commits preserve those pre-existing edits separately. The gate records revision `bbfd39e` plus the working-source fingerprint `fbbfcf58a7a9a2d2d2b7e6047a47e1ffbcb5159db1a4ad59dca2845b7f8db2c4`; source bytes were frozen during execution. Committing the VF-34 changes afterwards changes the Git revision, not those tested source bytes. No full live/e2e/nightly/release-tier gate is claimed.

`./install.sh --relaunch` succeeded with the stable Developer ID signature. Voice Flow is running from `/Applications/Voice Flow.app`; its local status endpoint returns HTTP 200, deep/strict signature verification passes, and deployed Watcher protocol/skill bytes match the repository. The nightly LaunchAgent loaded successfully. [Installation log](next-evidence-2026-09-08/installation.txt), [post-install verification and binary hash](next-evidence-2026-09-08/installation.json).

All four pickup tickets are in Waiting on Safet for user QA. Next and Doing were empty after completion.

### VF-62 sidebar correction

The queue editor now lives in **Queue**, immediately below Inbox in the main workspace sidebar. Menu/pill/overlay editing shortcuts route to that same page. The editor stays mounted across navigation, retaining its draft; visible rows refresh from the shared queue file. Queue is excluded from conversation capture routing and assistant-only header actions.

Validation for this follow-up: the targeted `queue_editor` suite passed (store persistence, external-edit conflicts, malformed-file preservation, metadata preservation, real Add/Remove actions, draft retention). The production app was rebuilt, signed and relaunched for live sidebar verification. The earlier full-gate result above applies to the prior batch; this follow-up uses targeted validation.

Live verification on the installed signed app: Queue is visible below Inbox; Add saved a temporary item; navigating Now → Queue retained the unsent draft; Remove deleted the temporary item. Test content was cleared and Queue left open. [Sidebar screenshot](vf62/queue-sidebar.png).
