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

Keys (OpenAI + OpenRouter) live encrypted via an Android-Keystore AES key.
There is no settings screen at all: on first launch the app finds the Mac
(Bonjour `_voiceflow-sync._tcp` + candidate probing), you click **Pair
Phone** in the Voice Flow menu bar, and the phone receives everything —
sync token, host list (Tailscale first, LAN fallback), port, both API keys,
vocabulary, model, cleanup setting. A 401 later (revoked token) drops the
app back to the pairing screen.

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
