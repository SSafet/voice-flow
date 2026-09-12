# Voice Flow update and verification — 12 September 2026

Product source: `d196e1368952e105d31415b51c6485146fcfbcea`.
Source fingerprint: `068fb2e58e3545e020327989a4724f81ad645eeb484a747985c7bfc7bda256a0`.

The full `--e2e` gate passed at 2026-09-12 16:57:40 UTC with an unchanged
source fingerprint: **166 registered checks** (82 unit, 12 live and 72 end-to-end
entries) and **23 signed-app scenarios**. See `full-e2e-evidence.json`,
`signed-e2e.json` and `full-e2e.log`. The bundled OpenCode cold probe and actual
Codex CLI both passed; `runtime-canary.json` preserves their results. The signed
app's verified updater selected OpenCode 1.18.30 for the end-to-end scenarios.

The Developer ID signed Mac app was installed and relaunched after the gate.
The new process reports a healthy backend with dictation available, and its
bundled runtime/SDK checksums passed validation. `mac-installed.json` records
the installed binary, source fingerprint, signing identity and health check.
The Android emulator runs the rebuilt regular APK; `android-installed.json`
records its matching installed hash. Both clients retain their existing data.

Two failures found during this update were fixed:

- A cold OpenCode turn tried to download its tool SDK inside the agent sandbox.
  The download failed and the turn timed out without reaching the provider.
  Voice Flow now bundles the pinned official tool SDK and Zod, verifies the
  archive, and prepares local package links before loading tools. A real cold
  native probe completed in 2.45 seconds with external networking disabled.
  Archive reproduction produced the identical SHA-256. The full gate repeats
  the real text/tool/skill/image/permission/cancellation probe. Signed-app
  testing also caught and corrected a path comparison between `/private/tmp`
  and `/tmp` when dependency children did not yet exist.
- Native cloud persistence callbacks scheduled another sync even when a save
  changed nothing or only projected incoming data. This created an endless
  request loop. Only real edits or persistence errors now wake the controller.
  The regression checks no-op, unchanged and projected saves, and the form
  settled with zero HTTP requests during a 22.435-second idle observation.

The test setup seeds its model catalog endpoint before startup, requests
shell approvals only for its own test session,
accepts only the bundled or checksum-verified staged runtime, and scopes its
test skill to explicit invocation. The Settings width check follows the
current model-and-effort row; selection and rendering are still exercised.
Production permission defaults and updater behavior are unchanged.

## Native and emulator evidence

| Evidence | Result |
| --- | --- |
| `android-build.json` | 21 JVM tests; debug and isolated QA APKs built |
| `android-cloud.json` | 19 checks on Android 14, real SQLite/Keystore and Atika HTTP; 1,200 records, retry after lost commit response, conflicts, restore, account isolation and revocation |
| `cross-device.json` | Swift → Android and Android → Swift; version 1, zero pending operations, zero conflicts |
| `android-local-sync.json` | 10 background LAN checks, including failed delivery, eventual retry, startup and Wi-Fi restoration |
| `swift-cloud-http.log` | Real Swift HTTP client, 1,200 records, conflict recovery, exact retry, credential refresh, cursor/redirect rejection and revocation |
| `swift-local-http.log` | Native LAN transport authentication, identity and concurrent deduplication |
| `mac-cloud-form.json` | Sign-in validation, challenge cancellation, revocation recovery, export selection, all three conflict choices, idle sync, saved history and sign-out |
| `android-installed.json` | Rebuilt APK hash matches installed emulator package; regular app left running |

The form test hosts the production SwiftUI form and controller in a disposable,
Developer ID signed normal window. A test-only URLProtocol forwards one reserved
hostname to the actual Atika auth/sync routers and an isolated PostgreSQL
instance. This proves native form/controller behavior; it does not prove TLS,
SMTP delivery or a click-through on the production borderless panel. Early
validation and revocation checks preceded the scheduling fix. Sign-in, all
conflict choices, idle behavior and sign-out were repeated on final sources.
`cloud-form-fixture.swift` preserves the exact test wrapper.

All records and accounts used by the sync tests were synthetic. Fixture servers
cleaned their records on shutdown, the isolated Android QA data was cleared,
and the regular Android app's data was preserved. No personal cloud sign-in or
upload was performed. No physical phone was connected. Long duration runtime
soaks and actual microphone quality are not established by these fixtures.
OpenCode model requests use a local provider fixture; the Codex smoke uses
the real authenticated CLI. The metadata-only sync boundaries in
`../../implementation-and-proof.md` still apply.
