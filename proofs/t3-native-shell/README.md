# T3 native host fixture

This builds the production `swift/Shell` host inside a small QA executable. It
does not include `AppDelegate`, the legacy canonical store, native providers,
capture services, or a server. It uses the real matching T3 web client supplied
by a separately owned local environment. It neither impersonates Electron nor
injects a `desktopBridge`.

Build only:

```sh
bash proofs/t3-native-shell/build.sh /tmp/voiceflow-t3-shell-build-UNIQUE
```

The output is an ad-hoc signed isolated bundle, with binary SHA256, source HEAD
and source status. Building does not open the app. A full optimized VoiceFlow
build is unnecessary for this fixture.

The first executable statement calls the existing `QALaunchIsolation.validate()`.
An envless GUI launch must exit 78 before reading stdin, initializing AppKit or
creating files. The test coordinator must verify that refusal on the exact
signed bundle before its authorized UI run. Never inspect an exited app with a
computer-control tool: that tool may relaunch it without the environment.

For the coordinated run, the process requires an explicit isolated
`VOICE_FLOW_CONFIG_ROOT` and non-daily `VOICE_FLOW_QA_PORT` /
`VOICE_FLOW_QA_SYNC_PORT`. It reads one JSON object from stdin until EOF:

```json
{"origin":"http://127.0.0.1:28471","environmentId":"the-approved-environment-id","credential":"supplied-through-private-stdin"}
```

Do not put the credential in argv, a URL, JavaScript, shell history, receipts or
logs. The fixture itself binds no ports. Its cookie/profile store is
nonpersistent; its compiled WebKit rule cache lives under the explicit isolated
root. It offers no native capture/voice capability callbacks. The only stdout
messages are fixed phase labels. Send SIGTERM only to the fixture PID owned by
the coordinator, then stop observing the app. Closing its ordinary window hides
it and leaves the attached environment running.

Approved build-only candidate proof layout is
`/tmp/voiceflow-t3-shell-proof-20260922/config`, environment origin port `28471`,
cookie-observer port `28472`, and QA port values `28473` / `28474`. These are a
coordination packet, not authority to launch or a claim that any listener exists.
The root coordinator supplies the final matching T3 client with the shared web
consumer and performs the single actual UI pass.

Required measured cases before cutover:

- Cookie bootstrap authenticates both primary HTTP and WebSocket without a
  token in renderer state. Another loopback port receives no session cookie.
- Opaque HTML preview cannot call the native bridge or its parent; mislabeled
  PDF/HTML, popups and top-level file navigation cannot gain native privileges.
- Native input reaches only its frozen composer; duplicate delivery does not
  duplicate text; stale/timeout/renderer loss retains the original capture.
- Cookie renewal wakes the existing T3 auth supervisor and keeps draft,
  selection and composer identity. Ordinary reconnect does not reload the page.
- Actual offline/reconnect, explicit renderer recovery, file open/save, window
  hide/reopen and owned process shutdown preserve expected behavior.

Policy tests and compilation alone do not establish any of these live outcomes.
