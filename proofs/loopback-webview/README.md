# Loopback proof (core work package K7)

This is not part of the Voice Flow application. It is a separate Swift package that
proves the arrangement the Mac shell rests on, before anything is built on it: a
`WKWebView` loading a page over plain `http` from a server inside the same program,
on the name `localhost`, bound on `127.0.0.1` and `::1`, with a per-launch header
secret on data requests and a one-use ticket for the WebSocket.

Run it:

    scripts/run-proof.sh /tmp/k7-proof

It builds, assembles two application bundles — one with the transport-security
exception for `localhost`, one with no transport-security key — runs both without
showing a window, prints a pass/fail table for each and exits non-zero if any check
failed.

The ports are 8799 for the proof's own server and 8798 for the stand-in development
server it frames. **The port numbers are not part of what is proved.** The Mac app
uses 8792, and the owner's daily Voice Flow build is listening on it while this runs;
this proof never touches it.

What was measured, and what it means for the designs, is in
`../../docs/runtime-proof/core/K7/FINDINGS.md`.
