# S1 captured-store validation, 22 September 2026

Production source commit: `3690d42f15dcc2f2cb12f86d1f44ccfbd90cce3c`, based on platform `6afa668`. The subsequent fixture-only commits correct macOS `/tmp` versus `/private/tmp` enumeration; no application source changed after the frozen release build began.

Executed checks, all passing:

- `swift build -c release -Xswiftc -suppress-warnings` — completed on the frozen production source, exit 0 (763.51 seconds).
- `bash tests/captured_context/test.sh`
- `bash tests/dictation_store/test.sh`
- `bash tests/captured_store/test.sh`
- `bash tests/captured_ingest/test.sh`
- `bash tests/captured_index_build/test.sh`
- `bash tests/captured_integrity/test.sh`
- `bash scripts/captured-index-proof.sh <synthetic isolated root> docs/runtime-proof/captured-data/S1/synthetic-2026-09-22` — completed, exit 0. Three source files, 293 bytes unchanged; complete before/after SHA256 manifests are in the synthetic proof directory. The independently invoked daily-root guard refused `/Users/safet/.config/voice-flow` before creating any evidence or index there.

The integrity suite executes real GRDB/SQLite transactions and FTS5, with synthetic files using the native watcher, bundle, dictation and SourceCollector formats. It proves source-step rollback, cursor rollback, incomplete-tail completion, rewritten/truncated sources, duplicate committed live notifications, bundle traversal rejection, private-context joins, cross-month edits/deletions, failed import retry/dedup, dated legacy identities and late backup/snapshot tombstone preservation. It also compares full source SHA256 hashes and canonical rows across a database rebuild.

The original whole-index fixture failed because its disk counter derived relative names by slicing differently normalized macOS paths. The final passing fixture uses FileManager's native relative-path enumerator. The production index and the separate proof script did not mutate source files. Earlier runs made while source was changing are not gate evidence.

These are focused store/ingest/rebuild checks, not the complete app release gate or signed-app captured-data acceptance. No daily installation, no recording, no production deployment and no paid model call were performed. App startup/committed callbacks, real phone sync, native capture in a signed isolated app, and a full real-archive-copy proof remain the integration gates described in `design/captured-store-integration-2026-09-22.md`.

The stricter unsupported-browser privacy proposal was not included. Main S1 preserves the baseline browser probing behavior; do not claim validated Safari/Firefox private-window detection.

## Integrated native lifecycle

Platform commit `a8d7446` connects the service to AppDelegate startup, watcher commits and Foundation notifications emitted after successful capture/transcript/shot or pending-audio writes. Notifications are scoped to the source root. Opening the latest externally written watcher review also requests catch-up; immediate background review-file observation is not implemented by this commit.

- The combined production release build passed on these unchanged Swift sources: exit 0, 1,079.20 seconds (`/tmp/voiceflow-platform-captured-wiring-build.log`).
- The selected `capture_store` regression passed (`/tmp/voiceflow-captured-native-commit-test.log`).
- The selected `captured_integrity` suite passed, including the new real `PendingAudioStore.save` → Foundation notification → background ingestion → GRDB row-observation path after startup catch-up (`/tmp/voiceflow-captured-native-lifecycle-test.log`). It invokes no direct catch-up or test-only hook for that live step. The 833-second harness duration includes waiting for the earlier release build's SwiftPM lock. Existing rollback, privacy, tombstone, source-hash and rebuild assertions pass in the same run.
- Platform `33d0c5f` adds the separate earliest-entry QA isolation guard; its selected suite passes. See the [QA relaunch incident assessment](../../voiceflow-mac/V1/qa-launch-isolation-incident-2026-09-22.md). These receipts do not certify unchanged daily data after that separate incident.

Native signed-app capture acceptance, real phone delivery, external review completion notifications, full real-archive-copy proof and query/retention integration remain open. The index retains a row after raw audio is removed; retrieval must consult source availability rather than report the cached `undelivered` state as current.
