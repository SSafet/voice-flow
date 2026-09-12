# Native Atika cloud sync — implementation and proof

Updated 12 September 2026. This branch adds opt-in cloud metadata sync to the
existing macOS and Android apps. The macOS application has not been installed
or launched as part of this work. Android acceptance uses an isolated emulator;
Atika deployment is tracked separately. The evidence below names the exact scope.

## What a person can sync

Settings → Sync on macOS offers Local network or Atika cloud. Cloud sign-in uses
Atika's existing email-code account, an HTTPS server origin, a server-created
device, and a refresh credential held in a separate Keychain item. Cloud mode
pauses the legacy LAN server. The account retains its local cloud history and
outbox after sign-out; switching back to Local network resumes LAN transport.
A pending code challenge can be cancelled to correct the email or server.
A rejected device session returns to the sign-in form with its saved account
details while retaining its local history and pending edits.

Each account has three independent export selections. Disabling one stops its
queued operations from being sent, keeps those operations locally, and leaves
existing cloud copies intact. Enabling it again checks the native history and
imports previously excluded content conservatively.

| Selection | Included | Excluded |
| --- | --- | --- |
| Inbox text | Pasted/kept dictation ID, text, destination, available timestamp and capture kind | Images, audio, screen captures, capture IDs, local paths, seen/read state, assistant-routed Inbox copies |
| Completed conversations | Saved Assistant conversation title, created/completed time, assistant display name; ordered user/assistant/note text with stable parent links, after a turn stops running | Runtime bindings and IDs, in-flight streaming state, grants, automation/job IDs, attachments and attachment notes, source selections, MCP sessions and external-agent push archives |
| Preferences | Vocabulary, OpenRouter model ID, speech-cleanup enabled flag | Provider/API keys, cloud credentials, hotkeys, permissions, server settings, runtime selection, other local settings |

The cloud reader exposes saved Inbox text, conversation branches and the three
preferences. Search operates over the full SQLite history; the view displays
at most 100 matching rows at once. Inbox projection retains native attachments
on records that already exist locally. Existing native render/retention caps
do not delete the independent cloud history.

“Continue this branch on this Mac” copies one selected parent chain into a new
local Assistant conversation. It does not adopt external runtime state. A
running local turn blocks that action. Incoming records do not invoke the LAN
wake-word path, start an agent, execute tools, or restore automation jobs.

This is the portable text/data portion of the shared agent workspace. Atika's
server-side agent broker and any explicit native agent data-source integration
are separate authority paths; the native sync session is a device session.

## Persistence and recovery

- `cloud-sync.sqlite` commits each account's portable values and immutable
  operation outbox in one SQLite transaction, with WAL and synchronous FULL.
  A received page and its cursor are also committed together. Operations keep
  their identity across retries, process loss, and later local edits.
- Native persistence hooks first save typed recovery intent to
  `cloud-sync-intents/`, then update SQLite, then let the existing native JSON
  write proceed. Interrupted intents replay in a persisted monotonic order.
  The outbox is never rebuilt from an in-memory upload result.
- Initial import saves byte-identical source copies plus hashes and counts in
  `cloud-sync-backups/`. Legacy ID-less Inbox entries receive one saved identity
  map and the same IDs in their native file before cloud capture. Malformed
  source files fail visibly and remain untouched.
- Unsupported or oversized records move into `cloud-sync-review/` with their
  original portable contents. Other valid records continue syncing. A later
  valid correction archives the old review copy rather than erasing it.
- Account state is partitioned by normalized server origin and Atika user ID.
  Durable source ownership prevents a locally visible record from one account
  being uploaded by a later account; newly appended messages inherit their
  existing conversation's account. Existing local history remains readable;
  this is an upload boundary, not separate operating-system user profiles.
- Refresh credentials use a dedicated Keychain namespace and atomic updates;
  isolated QA roots have a separate namespace. No provider credential encoder
  or LAN payload encoder is used for cloud requests. Redirects are rejected,
  cookies and caching are disabled, and plain HTTP is available only through
  explicit loopback test configuration.

Conflicts retain the server's proposal and the latest local value, block
automatic retry for that record, and allow choosing the local value, current
cloud value, or retained proposal. Every choice fetches the current version
and sends a fresh compare-and-swap operation. Superseded local pending edits
remain in retained recovery proposals. Other records continue syncing.
Deletion is a versioned tombstone; restoration is explicit. Deleting a thread
header leaves its message records available as retained history.

A changed server history epoch stops automatic sync and offers an explicit
baseline reload. Reload retains pending edits and conflicts and lets the
server compare them with the restored history. Old local records absent from
the restored cloud remain retained locally. No automated server backup/restore
or compaction interface is included in this native change.

## Verification

The complete `./scripts/test-agent-harness.sh --unit` gate passed on merged
code commit `9f3b151b99090854afa6b87427d2b6c39d281ccd`, including both
release/QA application builds, the new cloud suites and all existing
UI/runtime/history regressions. **82 registered checks have execution
receipts.** The final receipt is `evidence/merged-unit-evidence.json`, generated
at 2026-09-12 13:51:52 UTC from a clean source tree. Its fingerprint is
`37a3ea0ed02f1cfb0a9f33699887219a93e78f666225eecd3127c82f421c2073`.

Cloud implementation commit `0030d25` includes both native clients and their
tests/docs. Merge `9f3b151` incorporates main's `01fa66b` FLORA context-size
routing. The merge required no conflict resolution: `App.swift` and
`AssistantHistory.swift` changed separate regions. Review verified both cloud
persistence hooks and FLORA context-usage logic, and all 19 other main-changed
files remained byte-identical to `01fa66b`. `git diff --check` passed.

The real HTTP smoke and Swift ↔ Android exchange passed separately. The
precise Swift client/helper and Android source hashes still match their
passing cross-device and native receipts after the merge. The earlier
pre-merge full-gate receipt is retained in `evidence/unit-evidence.json` as
historical evidence; the merged receipt above is the current release check.

| Check | Evidence |
| --- | --- |
| `cloud_sync` | 1,200-record durable/repeated import and reopen; native UI eviction cannot create deletes; cross-account ownership; exact operation acknowledgment while a newer edit exists; replay and atomic page/cursor rollback; changed epoch; retained conflicts and explicit resolution; DTO/origin limits; per-account export selection |
| `cloud_sync_bridge` | Compiles the application support sources; excludes canary local paths, attachment metadata, runtime IDs and job IDs; avoids running transcripts; recovers interrupted journal writes in order; preserves corrupt source bytes; backs up legacy data; persists migration IDs; quarantines oversized rows while independent rows continue |
| Real Atika HTTP smoke | Actual auth router, sync router and PostgreSQL in the isolated loopback fixture; two Swift SQLite clients exchange 1,200 records through bounded pages; independent offline edits conflict; delete/explicit restore resolves; a committed write deliberately returns 503 and exact retry after client recreation/refresh leaves one version; foreign-account cursor, redirect and revoked-device cases fail without losing local outbox |
| Android native acceptance | 21 JVM tests and 19 isolated emulator checks passed, covering real SQLite/Keystore/HTTP, committed response loss, conflicts, tombstones/restores, selection, sign-out, account switching and revocation. See `android/tests/CLOUD_SYNC.md` and `cloud-device-receipt.json` |
| Swift ↔ Android | Freshly compiled final Swift product sources exchange records through Atika with Android's real SQLite client in both directions. Each result is version 1 with zero pending operations and zero conflicts. Source hashes and results are saved in `android/tests/cloud-cross-device-receipt.json`; reproduce with `android/tests/cloud_cross_device.py` |

The HTTP smoke uses synthetic owners and tokens, never production user data.
The fixture restricts itself to the explicit isolated PostgreSQL endpoint at
`127.0.0.1:55433` and removes its synthetic records on SIGTERM/SIGINT.

Reproduce the focused/native checks from this checkout:

```sh
./scripts/test-agent-harness.sh --unit --only cloud_sync
./scripts/test-agent-harness.sh --unit --only cloud_sync_bridge
./scripts/test-agent-harness.sh --unit

# In the sibling Atika checkout, with its workspace packages built and the
# isolated test database running, start the synthetic fixture:
ATIKA_REPO=/Users/safet/repos/atika \
DATABASE_URL=postgres://atika:atika@127.0.0.1:55433/atika_test \
CLOUD_SYNC_FIXTURE=/tmp/vf-cloud-sync-fixture.json \
./node_modules/.bin/tsx /Users/safet/repos/voice-flow-cloud-sync/tests/cloud_sync/server-fixture.mts

# In this Voice Flow checkout, while the fresh fixture is running:
swiftc -parse-as-library swift/CloudSyncModels.swift swift/CloudSyncStore.swift \
  swift/CloudSyncHTTP.swift tests/cloud_sync_http/main.swift \
  -framework Security -lsqlite3 -o /tmp/vf-cloud-http-smoke
/tmp/vf-cloud-http-smoke /tmp/vf-cloud-sync-fixture.json
```

The HTTP driver expects a fresh fixture because it deliberately creates data
and revokes one of its synthetic devices. The deterministic full unit gate
does not claim to execute this separate HTTP smoke.

## Remaining limits

Physical attachments/blobs, capture/source archives, assistant definitions,
skills/memory files, shared job execution and provider credentials are not
part of this metadata protocol. Records exceeding its 64 KiB payload boundary
need review; neither truncation nor silent omission is used. There is no
account storage-quota UI or history compaction in this wave. The Swift store
currently stores each account state as one JSON value inside SQLite, which
provides atomicity but needs a normalized-table performance pass for very
large histories beyond the tested 1,200-record import. Release/live runtime
soaks, macOS visual interaction and installation remain separate gates.
