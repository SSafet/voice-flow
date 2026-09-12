# Voice Flow — Android companion (phase 1, ticket #7)

A standalone Kotlin app that brings the two things you actually use on the
move — **dictation** and the **assistant** — to your phone, and syncs both
histories back to the Mac. No Play Store; sideload the APK. Zero external
libraries (HttpURLConnection + org.json only), so the build is offline-safe
and the APK is small.

## What it does

- **Dictate** — record → OpenAI transcription (`gpt-4o-mini-transcribe`) with
  the same vocabulary prompt + LLM cleanup as the Mac backend
  (`voice_flow/openai_transcriber.py` + `cleaner.py`), cleanup running through
  OpenRouter. Result lands on the clipboard and in history.
- **Idea** — same pipeline, flagged `kept`; after sync it shows up in the
  Mac's `dictations.json` and `tickets intake-pending`.
- **Assistant** — plain OpenRouter chat on the same `agent_model` the Mac
  uses; prompt by text, voice (the ● mic), or a shared/attached photo.
- **Store-and-forward** — recordings queue on disk when offline and transcribe
  when the signal returns; finished records sync to the Mac when it's reachable.
  Offline is a delay, never a failure.
- **Quick Settings tile** + **share target** (share text/image into the
  assistant).
- **Floating bubble** (ticket VF-51) — the Mac-pill experience on the phone:
  the side-key assist gesture (the `.Dictate` alias routes through
  `DictateTrampoline`, a no-UI own-task activity, so the app itself never
  surfaces) toggles a recording in `BubbleService` (a specialUse/microphone
  foreground service behind the "Display over other apps" grant). The dot
  is drawn over the current app **only while a take is in flight** — red
  pulse while recording (tap it to stop, or long-press the side key
  again), amber pulse while transcribing, gone at idle. The transcript is
  typed into whatever text field holds the cursor by `InsertionService`
  (an accessibility service — the bubble window is non-focusable so the
  field never loses focus), clipboard + toast when no field is focused or
  the field refuses (passwords). Takes ride the same queue → Transcriber
  pipeline as mode `"bubble"` — offline recordings surface on the clipboard
  later — and land in history/sync as normal `pasted` dictations. Toggle on
  the Record page (walks the overlay → mic/notifications → accessibility →
  battery-exemption grants); survives reboot via `BubbleBootReceiver`.
  Deterministic test seam: `am start-foreground-service` with `-e fresh_id
  <queue-item-id>` treats that queued item as just-recorded (insertion
  path); needs the service temporarily `exported="true"` on Play-image
  emulators (no root), and `appops write-settings` before `adb reboot` or
  the shell overlay grant is silently lost.

Keys (OpenAI + OpenRouter) live encrypted via an Android-Keystore AES key.
There is no settings screen at all: on first launch the app finds the Mac
(Bonjour `_voiceflow-sync._tcp` + candidate probing), you click **Pair
Phone** in the Voice Flow menu bar, and the phone receives everything —
sync token, host list (Tailscale first, LAN fallback), port, both API keys,
vocabulary, model, cleanup setting. An unreachable or unauthenticated address
never acknowledges pending uploads or silently clears the saved pairing.

## Build

```bash
cd android
# uses the Gradle already cached on this machine (9.3.1); or install Gradle 8.7+
gradle assembleDebug          # → app/build/outputs/apk/debug/app-debug.apk
```

`local.properties` points at the Android SDK (`sdk.dir`). Min SDK 29, target 34.

## Install & first run

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

1. Open the app on the same Wi-Fi as the Mac (or Tailscale).
2. Click **Pair Phone** in the Voice Flow menu bar (2-minute window; tests
   can open it via `POST 127.0.0.1:8792/api/pair-mode`, loopback-only).
3. Done — history syncs, keys adopt, dictate away. The **Quick Settings
   tile** starts recording instantly; those captures go to the inbox
   (tickets intake) *and* the clipboard.

The **Voice Flow** launcher uses the Mac's cream/amber waveform icon (adaptive
layers generated from `assets/icon_master_1024.png`). The invisible **VF
Dictate** (`.Dictate` activity-alias) starts quick capture as the phone's
digital assistant: choose it under Settings → Apps → Choose default apps →
Digital assistant app, then leave the Samsung side-key long press assigned to
Digital assistant. It deliberately does not add a second app-drawer icon.
While recording, a halo around the record button scales with live mic amplitude
(`Recorder.level()`, polled every 50 ms) so you can see the phone hearing you.

If Bonjour discovery can't find the Mac (some Wi-Fi networks filter mDNS
multicast), pairing also probes previously saved hosts — over adb you can
seed one: write `sync_hosts` (JSON array of IPs) into the debug app's
`shared_prefs/app.xml` via `run-as com.voiceflow.mobile`, then relaunch.

## Mac side

The Mac runs a token-protected sync server on port 8793 (`swift/Sync.swift`,
started by `AppDelegate`). It binds all interfaces so the Tailscale address
reaches it; every request needs `Authorization: Bearer <sync-token>`. It merges
incoming phone dictations into the live history store, archives assistant chat
to `mobile-chat.json`, and answers with recent dictations plus
`custom_vocabulary` / `agent_model` for parity.

## Prereqs (Safet)

- Tailscale on Mac + phone, same account.
- Mac energy settings: prevent sleep on power / wake for network.
- Phone: allow installs from unknown sources.

## Local sync reliability

For local use, keep both devices on the same Wi-Fi, the Mac awake, and Voice Flow
running. Keep the Mac firewall enabled, disable its **Block all incoming
connections** option, and allow **Voice Flow** in its app list. No router port
forwarding or cloud account is needed.

The phone rediscovers `_voiceflow-sync._tcp` each sync and remembers the address
that worked. When multicast discovery and saved addresses fail, it probes only
port 8793 on at most 254 neighboring Wi-Fi addresses, within the current subnet
and capped to the phone's /24. The fallback is bounded to 10 seconds and retried
at most every five minutes (a network change or explicit tap resets that delay).
Before sending its bearer token/history to any candidate (including
an old cached address), it checks a fresh HMAC challenge against its existing
pairing secret. This prevents an unrelated Mac or reassigned address from
receiving the credentials. Both apps must be updated for this check. The existing
HTTP transport remains intended for a trusted local network; the identity check
is not transport encryption.

Sync runs on app resume, after captures, on connectivity changes, and every
30 seconds while the phone app is open. Saving a new dictation, continuation,
or chat message also schedules a persisted delivery job immediately, independent
of the Activity. Android 12+ uses expedited delivery when quota permits, with
a regular-job fallback. Failed delivery retries with exponential backoff starting
at 30 seconds. A separate persisted 15-minute job catches up with Mac history;
both the Activity and bubble service ensure it is registered. Android can still
defer background work for battery/Doze or quota.

The bubble retries finished transcripts on startup and network return even when
its pending-audio queue is empty, and resets the discovery cooldown on a new
connection. A stopped job cannot finish a replacement run. New changes replace
the delivery job so an edit arriving at the end of an upload is not stranded.
The Record page shows the last successful sync and a tap-to-retry status.
A sleeping/offline Mac means changes wait on the phone until a later retry.
`VoiceFlowSync` logs contain trigger, pending count, outcome and elapsed time;
they contain no transcript, host, token, or API key. The last attempt, trigger,
success, error and pending count are also recorded in the app preferences.

Uploads merge under a shared phone-store lock, acknowledging only the versions
actually sent, so concurrent captures and Continue edits survive. The Mac
serializes sync requests and completes upserts before returning its history.

Targeted checks (no full-release-gate claim):

```bash
gradle -p android testDebugUnitTest assembleDebug
python3 tests/local_sync/test_sync.py
gradle -p android assembleSyncQa
python3 tests/local_sync/test_android_delivery.py --serial emulator-5580 \
  --evidence /tmp/voiceflow-sync-evidence.json
```

`syncQa` installs as **Voice Flow Sync QA**, a separate package, store and
Keystore. Its driver and shell-accessible bubble service exist only in that
build. The device check uses synthetic records and an isolated HTTP fixture;
it never launches the main Activity or forces Android jobs to run. Use an
Android emulator reachable through `10.0.2.2` (the default test host).
