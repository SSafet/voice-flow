# Android cloud sync

The phone has an explicit **Local only / Atika cloud / Paired Mac** choice in
Settings & sync. Cloud uses the existing Atika email-code identity and an
Android device enrollment. Access tokens remain in memory; refresh successors
commit through Android Keystore encryption before use. Signing out keeps the
account's local records, cursor, conflicts, review copies, and immutable outbox.

Cloud DTOs cover dictation text, conversation headers/completed messages with
parent IDs, vocabulary, the OpenRouter model ID, and cleanup preference. They
cannot serialize provider keys, LAN secrets, device permissions, local paths,
recordings, attachments, or runtime bindings. Provider keys can be entered in
Settings and remain on this phone. The LAN transport retains its own existing
pairing and protocol; selecting cloud stops automatic pairing and LAN delivery.

Every local edit is durably journaled before updating the compatibility files.
SQLite commits portable records and immutable operations together. A successful
reply must identify the exact sent operation and confirm its expected version,
payload, tombstone state, and sequence before removing it. A later edit cannot
be cleared by an earlier upload. Changes/cursor advancement are one transaction;
a changed server epoch requires visible baseline review. Conflicts block only
the affected record; resolution uses the latest cloud version, retains replaced
local proposals, and acknowledges only the chosen conflict.

Uploads can be selected by data type per account. Excluded operations stay
local and are eligible again when selected. A source record belongs to its
original account, so signing into another account does not republish it.
Cloud records from all supported collections remain readable locally. Remote
conversation branches are shown as cloud threads and never replace the current
phone assistant context implicitly.

Legacy import retains original file bytes, persists generated IDs before
queueing, and imports every retained row before compatibility UI caps apply.
Oversized or invalid portable edits become visible local review copies; valid
records continue syncing. Correcting a review copy queues a valid edit while
retaining the original. Deleted records retain their last live payload for an
explicit restore. SQLite reads large state in bounded slices rather than relying
on Android's CursorWindow row ceiling; transaction snapshots avoid repeatedly
parsing the same retained history on the main thread.

## Verification

`testDebugUnitTest` covers the pure engine/HTTP client plus the existing LAN
merge/identity contracts. `CloudEngineTest` covers 1,200 records, restarts,
concurrent edits, exact acknowledgments, account partitioning, upload selection,
conflict isolation, baseline changes, deletion/restoration, invalid record
retention, and rejection of LAN/secret-shaped DTOs. `CloudHTTPTest` covers
refresh single-flight, response loss, identity mismatch, durable-save failure,
logout during refresh, and an exact mutation retry after 401.

The isolated `syncQa` APK has package `com.voiceflow.mobile.syncqa`, separate
files/SQLite/Keystore from the daily app. `cloud_device_integration.py` invokes
its QA-only instrumentation against `tests/cloud_sync/server-fixture.mts`,
which uses the actual Atika auth/sync routers and synthetic owners in the local
test PostgreSQL database. It checks real Android persistence, HTTP behavior,
response loss after server commit, conflicts, independent delivery, tombstones,
restores, per-account selection, redirects, sign-out, account switching, and
device revocation. The receipt records the tested Android source hash.

```sh
# Build the regular and isolated packages; run all Android JVM contracts.
JAVA_HOME=/path/to/jdk17 ANDROID_HOME=/path/to/android/sdk \
  gradle -p android testDebugUnitTest assembleDebug assembleSyncQa --offline

# Start a fresh synthetic fixture per full run (from the Atika gateway folder).
ATIKA_REPO=/path/to/atika \
DATABASE_URL=postgres://atika:atika@127.0.0.1:55433/atika_test \
CLOUD_SYNC_FIXTURE=/tmp/android-cloud-fixture.json \
  pnpm exec tsx /path/to/voice-flow/tests/cloud_sync/server-fixture.mts

adb -s emulator-5554 install -r android/app/build/outputs/apk/syncQa/app-syncQa.apk
python3 android/tests/cloud_device_integration.py \
  --fixture /tmp/android-cloud-fixture.json --serial emulator-5554
```

The test refuses non-loopback fixtures and non-emulator serials. It clears only
the isolated QA package. Run fixture fault injection serially: a shared
"drop next mutation reply" applies to whichever synthetic client writes next.
Repeated debug logins respect the real server's authentication rate limit.

The final cross-device check compiles `SwiftCloudFixtureClient.swift` against
current `swift/CloudSyncModels.swift`, `CloudSyncStore.swift`, and
`CloudSyncHTTP.swift`, then exchanges a dictation in both directions through
real SQLite outboxes. It uses an isolated temporary Swift database and an
in-memory synthetic credential vault; the Android side uses its real Keystore.
Use a fresh fixture if previous debugging exhausted the auth limiter:

```sh
python3 android/tests/cloud_cross_device.py --fixture /tmp/android-cross-fixture.json
```

Saved receipts: `cloud-device-receipt.json` and
`cloud-cross-device-receipt.json`. Native UI captures are `cloud-main.png` and
`cloud-settings.png`. No model calls or production user data are used.
