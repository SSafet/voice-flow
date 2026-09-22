# Captured-data store integration review

Scope: S1 integrated onto platform `6afa668`, using only the captured-data implementation and its call-site changes from the older S1 worktree. Runtime dependencies, generated contracts, canonical thread DB/recovery and App/QA wiring remain owned by their existing platform work.

## Adoption decision

Use the platform's pinned GRDB 7.11.1 and the system SQLite FTS5 for transactions, WAL readers, SQL persistence and search. The captured index is a separate **derived** database; it must never become a migration in the canonical thread database. Its original sources remain where they are. Existing native recording, AppKit/CoreGraphics/Accessibility observations and file formats remain the owners of collection. S1 is format adaptation and product policy, not another database implementation or recorder. Adopting a second screen recorder would not import the existing VoiceFlow formats or satisfy the no-additional-collection requirement.

## Review changes

- Import only S1 paths and the required consumers. Do not restore the older branch's OpenCode runtime, contracts, package manifest, installer build logic or thread store.
- Put every ingest step's item changes, SQLite FTS trigger changes and source cursors in one GRDB writer transaction. Invalid input cannot publish half a bundle/day or advance its cursor.
- Use the same watcher parser for committed live notifications and catch-up. Remove the separate live accumulator, which mishandled controls and counted duplicate notifications.
- Preserve incomplete source lines, detect rewritten/truncated watcher sources by prefix hashes, and do not mark bytes appended during a read as already seen.
- Fold archive months together so a changed older month cannot resurrect newer tombstones. Keep a continued dictation in its original archive file, and archive the old 200-entry projection before replacing it.
- Publish dictation observer callbacks only after archive/file persistence succeeds. Keep failed imports retryable, expose failures, and use stable legacy identities.
- Support actual backup filenames and SourceCollector's `snapshot.json` plus full-text item files. No preview substitutes for the original speech. Initial `dictations.json` is indexed before the monthly archive exists.
- Reject bundle paths that traverse outside the data root. Carry private span status into joined shot/bundle OCR eligibility. Accept the sanitized host/path format that the native watcher itself writes.
- Replace captured-service fatal startup failure with inspectable optional startup/error state. One damaged source cannot starve all other streams.

## Verification status

Focused verification uses synthetic temporary config roots and the actual source formats. Tests cover store/FTS consistency, context mapping, dictation archive, six ingesters, disk counts/rebuild, and fault/retry/source SHA256 checks. The final handoff records executed commands and outcomes; this document alone is not a passing receipt.

A read-only directory listing of the daily configuration identified the real backup and snapshot filenames. SourceCollector/Capture.swift supplied the format definitions. No daily archive bytes were copied or modified, no recording was enabled, and no daily app was installed.

## App integration and remaining running-system gate

1. Initialize `CapturedService.shared` during isolated app startup; surface `startupError` if unavailable. Run `LegacyDictationRecovery.run(root:)`, surface its failures, then start catch-up. Archive writes belong to preservation/import, never the read-only index proof.
2. Register `workflowWatcher.addCommittedObserver` to `service.observe(stream:fields:at:)`. This is after the recorder writes its source line. Preserve the existing trigger callback; indexing/rebuild must not emit trigger events.
3. Call `catchUpSoon()` after committed bundles, shots, reviews and pending-recording changes. DictationStore's observer is installed by `start()`. Integrate these through existing callbacks rather than replacing unrelated consumers.
4. In a signed isolated app, create a real native dictation, screenshot/bundle and watcher span; verify immediate index/search and process restart without duplicates. Deliver a real phone dictation through sync and independently verify its origin device and text.
5. Run `scripts/captured-index-proof.sh <isolated full archive copy> <evidence directory>` and independently compare source kind counts, hashes and missing-image records. Rebuild the index and repeat. The script refuses the daily root and records complete source SHA256 manifests.
6. Finish S2/S4/S5 query/UI/OCR, attachments/links and retention/recovery integration before claiming the whole captured-data product complete. S1 does not introduce a retention sweep or enable new ambient collection.

Browser private-window detection is a separate review item: the old watcher and initial ContextProbe have no reliable Safari private flag and treat an unknown Chromium mode as normal. A separately scoped conservative-policy commit can exclude title/URL/OCR for unsupported or unverified browser windows; no actual private-window acceptance has yet been performed. Main S1 storage does not depend on that policy change.
