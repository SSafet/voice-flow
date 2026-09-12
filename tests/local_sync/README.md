# Local sync checks

Run `python3 tests/local_sync/test_sync.py` from the repository. It compiles the
production SyncServer and SyncIdentity with an isolated in-memory history fixture
and temporary config root, then verifies challenge/response identity, rejection
of invalid credentials/JSON, upsert-before-response ordering, and concurrent
retry deduplication. It does not exercise AppKit persistence or claim release-gate
evidence.

Android: `gradle -p android testDebugUnitTest assembleDebug` covers concurrent
phone edits/captures, stale responses, deduplication, recent-history ordering,
identity verification and redirect rejection.

Device validation on 2026-09-08 (SM-S938B + signed Mac app):

- Local sync succeeds with the Mac firewall enabled and VoiceFlow allowed.
- Cleared all saved phone host addresses; multicast discovery was unavailable,
  and the authenticated subnet fallback recovered the Mac's current address.
- The latest 20 Mac history IDs are present on the phone after synchronization.
- The phone renders last-success time and a tap-to-sync control.
- With the Activity backgrounded, a forced run of the registered persisted
  Android job completed and advanced the last-success timestamp. This proves
  the job path, not Android's exact background scheduling latency.

## Automatic delivery regression (VF-71)

Build `gradle -p android assembleSyncQa`, then run:

```bash
python3 tests/local_sync/test_android_delivery.py --serial emulator-5580 \
  --evidence /tmp/voiceflow-sync-evidence.json
```

This installs/clears only `com.voiceflow.mobile.syncqa`. The production package
and its data are untouched. A QA-only driver saves synthetic dictations through
the production Store, then exits its process. The test observes Android starting
the real SyncJob and delivering over HTTP, without opening MainActivity or
forcing a job. It checks new captures, continuation updates, preservation during
a temporary endpoint outage, automatic retry after recovery, bubble startup
with finished transcripts but no queued audio, and an existing bubble recovering
after the emulator's Wi-Fi is disabled and re-enabled. Evidence includes delivery IDs,
times and redacted sync logs. `--expect-old-failure --apk <baseline-qa.apk>` runs
the same save/startup paths against the pre-fix build to demonstrate the gaps.

The HTTP fixture exercises the Android scheduling/transport path; `test_sync.py`
separately exercises the production Swift server. These checks do not establish
Samsung scheduling behavior or prove installation on Safet's physical phone.
