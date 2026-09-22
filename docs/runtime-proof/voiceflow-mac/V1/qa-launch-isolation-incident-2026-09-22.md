# QA GUI relaunch isolation incident — 22 September 2026

A computer-control observation automatically relaunched the temporary QA bundle after its isolated recovery window was closed. LaunchServices did not retain the harness environment. The old QA executable consequently initialized the default daily data root. The unexpected process was stopped; the installed daily app (PID 1934) was not stopped or relaunched. No daily files were restored or removed. The user was informed.

The old executable's SHA-256 is `30d87d5e084d78081f0b710e950aeb3512b4a31e59084f5fa04728f77bd78fbc`; temporary bundle `/tmp/voiceflow-v1-recovery-final-build/Voice Flow QA.app`; unexpected PID 27099. It must not be launched again. The new guard is a separate commit from the store-recovery implementation.

## Evidence and limitations

Private current copies, hashes, timestamps and redacted diagnostic inventories are preserved outside the daily root in `/tmp/voiceflow-v1-recovery-incident-20260922` (0700). The candidate observation window is 13:52:30–13:54:15 UTC, not an asserted exact process lifetime. The new canonical main/WAL/SHM files date from 13:52:33 UTC. Settings, slots, assistant sessions, pushes and the model catalog were modified at 13:52:35–36 UTC. The new canonical database contains the two schema migrations and an installation identity, but no project/thread/turn/item/attachment/event/command rows.

The recursive manifest captures 307 files with timestamps in that window: 294 source snapshots, three assistant-thread metadata files, one overlay, one queue file and eight root files. These are candidates, not a causal attribution: the daily app was still running. No watcher or captures file fell within the bounded timestamp window. The log excerpt is preserved separately because a later append can move a file outside that window.

A prior read-only session inventory from the parent task counted 36 conversations, 276 messages and 43 notes (124444 bytes). The preserved current copy has 36 conversations, 277 messages and 44 notes (124688 bytes): one new note at 13:52:35.305658 UTC matches the launch message about 18 pending audio recordings. Both inventories have one attachment note, 63 seen flags and 36 persona sessions; the current copy has no duplicate conversation/message IDs. These limited counts and the identified new note do not prove that earlier content or other fields are unchanged. There is no before-file copy.

The interval log confirms public model-catalog refresh, backend startup and local sync on port 18793. The QA provider-key implementation compiles out native Keychain read/write/delete operations and uses in-memory values. The saved cloud account is local and signed out, with a timestamp preceding this incident; the cloud sync code returns before vault access in that state. No paid model request or credential mutation appears in the retained log. No network/Keychain audit was active, so absent log entries are not a complete proof of absent activity.

## Correction

`main.swift` now validates QA isolation as its first executable statement, before `NSApplication`, `AppDelegate`, `VoiceFlowPaths`, logging or other singleton initialization. Missing/relative roots, overlap with daily data, parent traversal, aliases including nonexistent children and dangling symlinks, production ports and colliding QA ports are refused with exit 78. The check creates no directories and writes only its refusal to stderr. Production builds retain their normal startup.

The focused unit suite is part of the normal harness (`--unit --only qa_launch_isolation`). `tests/qa_launch_isolation/signed_probe.py` refuses old binaries lacking the guard, verifies the signed temporary QA bundle, launches it without VoiceFlow environment variables and with an explicit daily root, and compares recursive daily-root metadata plus every direct root file's SHA-256. Concurrent daily activity invalidates the zero-change receipt rather than being filtered away. Native inspection must never query an app after closing it.

Final signed executable refusal and recovery acceptance are recorded separately after compiling the guard from frozen source.
