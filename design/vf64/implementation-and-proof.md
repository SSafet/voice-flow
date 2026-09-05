# VF-64 — data and agent workspace

## User outcome

Replace the cramped main application panel with one navigable workspace. Make locally collected data visible and inspectable, let the user author instructions for its use, and explicitly select that data for assistant conversations and independently configured automations. The notification pill remains the quick interaction surface.

## Governing decisions

- Persistent navigation separates reading (Now, Inbox, Threads) from durable objects (Data, Assistants, Automations). Settings and Speech use the same workspace.
- Source detail shows collection health and actual saved evidence before configuration. Failed collection retains the last successful copy.
- Collection belongs to the app, independently of whether an agent or the desktop watcher is running. Agents consume frozen bounded snapshots.
- Source guidance is authored configuration; website/document/email contents remain untrusted evidence.
- Data selection and permission to act are separate. Normal mode retains existing runtime capabilities. Review copies only uses app-managed OpenRouter inference with no tools, command process, browser, mailbox connection, or action dispatcher.

## Connected decisions

| Branch | Shipped choice | Evidence |
| --- | --- | --- |
| Main navigation | Persistent workspace rail with one content pane; 920×680 and 720×540 layout | Signed AppKit screenshots and navigation walkthrough |
| Existing product | Canonical assistant/MCP thread renderer, Inbox, Now, system agents, Settings, Speech remain reachable | Existing harness plus destination screenshots and capture-focus assertions |
| Collection ownership | Typed in-app collectors; independent timer and bounded operation queue | Local HTTP, pause/cancel, folder and MIME contracts |
| Storage | sources-registry.json + source-collection-status.json + immutable source-snapshots; outside deployment-owned sources/ | Restart, atomic save, retention and disconnect tests |
| Connection types | Public HTTP(S) website; local text folder; exported EML/mbox folder | Real loopback website and local document/mail fixtures |
| Built-ins | Read projections of Desktop activity, Dictations, Captures and Assistant conversations | Actual isolated store-format tests; malformed input surfaces errors |
| Instructions | Editable per-source guidance attached with its selected captured evidence | Source editor save, next-context and frozen-context tests |
| Assignments | Assistant selection; automation starts from assistant selection then owns independent IDs | Duplicate/reopen and A/B non-inheritance tests |
| Copies-only authority | Tool-free app-managed provider request through credential/budget gateway | Real loopback provider: no exposed tools, zero mailbox requests, action response rejected |
| Recovery | Explicit error plus last-good timestamp, Retry, Pause/Resume, retained history | Collection failure/retry and snapshots |
| Drafts | Route-preserved fields/selection/scroll; async collection does not overwrite active text | Actual SourcesView tests and workspace walkthrough |

## Alternatives eliminated

The three visual directions are standalone HTML artifacts in this directory. A three-column library squeezed instructions and conversations; an activity-first desk left durable data hidden. The workspace rail best serves the user’s stated need to understand available sources.

Adding only Finder links fails in-app inspection and assignment. Letting every agent fetch its own data fails reusable local collection. Extending the desktop watcher’s lifecycle makes website collection depend on screen capture being enabled. Arbitrary executable source plugins add inherited macOS permissions without helping the supported typed collectors. A new external service adds lifecycle cost without an out-of-app collection requirement.

For copies-only review, prompts or permissive runtime profiles cannot guarantee mailbox isolation. A new restricted action broker would add operations beyond this task’s analysis requirement. The selected no-tools review supplies useful analysis, summaries and drafts while making action execution unavailable. It uses OpenRouter even when the conversation’s normal runtime is Codex; the UI says so and missing credentials fail without fallback.

## Practical scope

Website collection uses HTTP and does not sign into a browser or execute page JavaScript. Email collection monitors exported files, not a live mailbox account. The UI names these connections accurately. Sources collect while Voice Flow is open. Per-source collection is bounded to 200 items, 2 MB per file, 12 MB per refresh and depth 5; skips are visible. Managed snapshot retention also has a 100-copy ceiling. Agent context is bounded and clipping is labelled.

## Proof artifacts

Automated source contracts: tests/data_sources/main.swift; actual source UI contracts: tests/data_sources/ui/main.swift. Review and selection contracts: tests/source_review/main.swift; real model-gateway HTTP proof: tests/source_review/transport_proof.py. Signed app walkthrough: tests/vf64_workspace_e2e.py. Final results, commands and screenshots are in [delivery evidence](evidence/README.md) and recorded with the VF-64 ticket.
