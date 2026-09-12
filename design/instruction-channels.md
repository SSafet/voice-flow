# Assistant instruction channels

Voice Flow prepares two separate strings for every turn. `AgentPromptComposer`
builds both, and `AgentTurnRequest.instructions` keeps authored behavior separate
from `prompt` throughout foreground turns, automation runs, and runtime recovery.

| Input | Destination |
| --- | --- |
| Voice Flow role and reply rules | Instructions |
| Assistant identity and editable persona | Instructions, refreshed every turn |
| Selected skill bodies (subscription CLIs) or descriptions (OpenCode/review) | Instructions; OpenCode also retains its selected native skill projection |
| User-authored guidance for selected sources | Instructions, frozen with that turn's source copies |
| CLI communication, data-location, and access guidance | Instructions |
| Core memory facts | User context |
| Canonical conversation handoff | User context |
| Imported source copies, timestamps, and collection issues | User context |
| Current user request or automation task | User message |
| Screenshots | Existing user attachment channel |

Codex app-server uses `developerInstructions`; the exec fallback uses the
`developer_instructions` config override with TOML escaping. Claude Code uses
`--append-system-prompt` on every invocation, including resume. OpenCode uses
the message request's `system` field. These paths preserve runtime defaults.
Source reviews combine assistant instructions with their app-owned review
constraints in the system message and continue to expose no tools.

The continuity router and speech-cleanup agents put their editable briefs in
Codex developer instructions. Their delimited input and required output schemas
remain app-owned. Speech synthesis already uses the provider's dedicated
`instructions` field and needs no change.

Old runtime bindings lack `instructionVersion` and rebuild once from canonical
history, leaving saved user conversations intact. Codex 0.153.2 was observed to
retain its original developer message despite an override on resume (both
app-server and exec). Voice Flow therefore persists a SHA-256 fingerprint of
the supplied instructions: unchanged Codex instructions resume normally;
changed instructions create a fresh external session with canonical context.
Memory updates and refreshed source copies do not change this fingerprint.

Regression coverage lives in `agent_prompt`, `codex_runtime`, `codex_appserver`,
`claude_code_runtime`, `opencode_runtime`, `opencode_http`, `source_review`,
`assistant_history`, `assistant_continuity`, `speech_sanitizer`, and
`system_agents`. `codex_live_turn` additionally checks both actual Codex adapters
for instruction priority, unchanged-instruction resume, and instruction edits.
