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
