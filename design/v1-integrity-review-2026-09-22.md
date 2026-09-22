# V1 canonical store: integrity correction and remaining cutover work

Reviewed the five V1 foundation commits ending at `90b9362` against
`atika/docs/architecture/platform/plan/mac-v1-thread-store-brief.md` and the
governing platform design. This branch applies that foundation to VoiceFlow
platform `208a1f5` and copies the authoritative generated contract from Atika
`1921c36f` using `scripts/sync-thread-protocol.sh`.

## Corrected integrity defects

- `ThreadStore.settle` previously read the command ledger, ran the work, and
  inserted its result in three separate steps. A concurrent duplicate executed
  twice; failure or process death after mutation could leave no settlement.
  Lookup, canonical mutation, event/outbox append and settlement now use one
  SQLite writer transaction. The closure receives that transaction explicitly.
  Same-ID replay requires matching method, thread and parameter hash.
- Project commands join that transaction. A failing relocate rolls back both
  the project path and every thread workspace/event. Replaying an old command
  returns its original result even after another command edits the project.
- Overflow text previously overwrote `<item>-full.txt` before SQL commit. A sink
  failure rolled back the old attachment hash but left replacement bytes in
  that file. Full text now has immutable content-hash identities. Complete bytes
  are staged then renamed before their row commits; old event revisions remain
  readable. Rollback cleanup queues a fresh writer transaction after GRDB has
  finished unwinding the aborted scope. It touches only a file created by the
  failed transaction and checks all references before deleting it.
  This handles another pool committing the same bytes after rollback releases
  the original lock. Cleanup failures retain bytes rather than risking data loss.
- Store runners used `if ! binary; then status=$?`, converting assertion failures
  to exit zero. They now propagate build, compile and assertion status, clean up
  isolated temporary roots, and link the current SwiftPM GRDB object/module map.
  The four V1 suites are included in the capability/evidence catalog.
  Honest execution also exposed recovery tests issuing WAL checkpoints inside
  transactions; those checkpoints now execute outside a transaction as SQLite
  requires.

`settle` guarantees canonical database admission, not exactly-once effects in an
external runtime. A future send commits its durable accepted command/turn first;
the turn engine executes it after commit. Never run a provider call, tool action
or runtime launch inside the settlement closure. Failed transactions are safe to
retry. A process dying before file cleanup can leave complete unreferenced bytes;
retry verifies/reuses them. Existing committed bytes are never swept speculatively.

## Regression proof

The event suite uses actual SQLite, real attachment bytes and SHA-256 hashes. It
tests failed and successful overflow edits, failure while reusing committed bytes
from another pool, and a controlled interleaving where a second pool commits
before the first pool's rollback cleanup resumes. It also tests a late settlement
insert failure after item/event/outbox/file writes, concurrent duplicates through
two independent pools, and a child process exiting before settlement, followed
by a retry. Project tests inject a relocation failure and replay an earlier
command after a newer edit. Runner tests deliberately return nonzero build,
compile and assertion codes, including when the runner is called in a shell
conditional that disables inherited `errexit`.

Validation completed on 22 September 2026: all four V1 suites passed with the
regressions above; the base `thread_store` harness suite passed against SQLite
3.54.0 with FTS5 and both migrations; the final release app build passed in
110 seconds. The contract sync's 14 checks, generated-contract self-check
(586 decoded examples, 74 rules), manifest validation and capability catalog
also passed. These are scoped validation results, not a claim of a new complete
V1 release gate or signed-app recovery drill.

The preceding OpenCode v2 worktree's broad unit run observed all 57 suites and
release/QA builds passing, but its final evidence audit rejected a source
snapshot transition during execution. That run has no valid full-gate receipt.
Its explicitly limited observation is saved at
`/tmp/voiceflow-opencode-v2-inspection/unit-observation-644ebff.json`; it must not
be represented as successful formal gate evidence.

## Remaining V1 task 5 and production recovery gap

This correction does not complete V1 acceptance. The original branch lacks
`ThreadStoreQA.swift`, authenticated `GET /__qa/thread-store`,
`scripts/v1-observe-damage-drill.sh`, and the signed QA damage-drill evidence.
Production startup still calls `ThreadDatabase.shared()` directly; it does not
gate canonical reads/sends through `ThreadStoreLaunch.open` or construct the
recovery window. The isolated recovery suite is not evidence that the real app
shows recovery on a damaged database.

Before cutover, review recovery's schema handling too: daily backup suppression
does not ensure a distinct pre-upgrade backup for every pending schema change,
and repair currently marks current migration identifiers applied without proving
that each corresponding recovered schema exists. Neither behavior is changed by
this bounded correction.

## History and Today.md are the next separate boundary

V1 intentionally deletes no legacy stores. The V2 importer must stage its new
database/persona trees, preserve conversation/message IDs and full logical text,
verify ordered hashes/counts and persona bytes, and publish only after readback
verification. Malformed history must fail visibly; it must not be skipped.
External bindings must be marked dirty where working directories change. Legacy
files must be moved aside only after verification and remain recoverable across
interruption. Overflow comparisons must include the full attachment text, not
only the truncated SQL display text.

The governing Today.md migration preserves open Queue entries, completed entries,
and historical daily-focus text in distinct imported sections. Current acceptance
for VF-62 also requires the useful Queue actions: add, remove, reorder and stale
edit protection. Merely writing a Markdown file does not replace those actions.
The replacement should preserve unrelated free text and reject conflicting saves
using a document revision; do not remove the old editor/writer before that parity
and lossless readback have been demonstrated.

Per-turn Today context must carry path/date/timezone/modified time and explicit
empty, unreadable or truncated state. It belongs to turn input, not durable
instructions, so editing Today must not force native-session reseeding. Preserve
the original imported focus date: writing a new file today must not accidentally
promote stale focus text or completed Queue entries into today's actionable work.

No daily app, owner configuration, installed bundle or production service was
changed. Importer/Today implementation, Task 5 UI plumbing and V3 runtime launcher
integration remain separate work.
