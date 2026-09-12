# Context-aware FLORA wake routing

The continuity router receives a bounded `CONTEXT_USAGE` data block alongside
the current conversation excerpt and incoming message. It contains the selected
runtime, last model request's input/output footprint, reported context capacity
and percentage when known, and the saved transcript's message count and rough
UTF-8-bytes/4 text estimate. Unknown values are explicit. Text estimates exclude
tool results, instructions, and images; they never authorize the fast path.

`RuntimeBinding.contextUsage` persists independently for each conversation and
runtime. Foreground and automation completions store the latest measurement.
Fresh runtime sessions and completions without telemetry clear old measurements.
Codex uses `thread/tokenUsage/updated.tokenUsage.last`, including cached input
exactly once. Its exec fallback reads `last_token_usage` from a bounded tail of
the exact saved rollout; the same reader supplies older Codex conversations at
wake time. Session identity is checked, reads are bounded, and a compaction
without subsequent telemetry invalidates an older measurement. Cumulative
billing counters are never substituted for context size.

OpenCode includes non-cached input, cache reads/writes, output, and reasoning.
Claude Code uses the last main-agent assistant message's input and cache counts;
its per-step output counter is a placeholder, so output and capacity remain
unknown. Runtime-reported sizes describe the last request, not a promise about
the next request after compaction, model changes, or newly added input.

The three-minute shortcut applies only to a resumable, measured context with
known output, below 32,000 tokens and below 25% of capacity when capacity is
reported. Large, stale, or unmeasured contexts go through the classifier even
when recent. Both Codex and the API fallback receive the same context policy:
prefer a fresh conversation for independent tasks, especially with large
context; preserve dependent follow-ups even when large. A shared broad project
alone does not make tasks dependent. Empty drafts and protected/completed
conversation routing are unchanged, as is visible reuse on classifier failure.

Coverage: `assistant_continuity`, `assistant_history`, `codex_appserver`,
`codex_runtime`, `claude_code_runtime`, and `opencode_http`. `codex_live_turn`
checks real telemetry from both Codex transports. With `VF_CONTINUITY_LIVE=1`,
the continuity suite tests unrelated, dependent, and same-project independent
requests through the saved API model with a 142k-token context fixture.
