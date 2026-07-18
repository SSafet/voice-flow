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
On a fresh install you only enter the sync host/port/token — the phone adopts
both API keys from the Mac on the first sync.

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

1. Open the app → **Setup**.
2. Enter **Mac sync host** (the Mac's Tailscale IP; `10.0.2.2` from an
   emulator), **port** `8793`, and the **sync token** from
   `~/.config/voice-flow/sync-token` on the Mac.
3. **Save** → **Sync now**. The phone pulls your dictation history and adopts
   the OpenAI + OpenRouter keys. Dictate away.

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
