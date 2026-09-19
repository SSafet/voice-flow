# K7 — the Mac loopback arrangement, proved in a running web view

What was run: `proofs/loopback-webview/scripts/run-proof.sh /tmp/k7-proof`, which builds the
proof package, assembles two application bundles from the same executable and runs each one.
Run on 2026-09-19.

Where: Safet's Mac. macOS 27.0 (build 26A428), Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.0
(build 27A266a). Hummingbird 2.26.0 with hummingbird-websocket 2.7.0, pinned exactly in
`Package.swift` and recorded in `Package.resolved`.

Ports: 8799 for the proof's server, 8798 for the stand-in development server it frames.
The port numbers are not part of what is proved. The owner's daily Voice Flow build was
listening on 127.0.0.1:8792 throughout and was not touched: `lsof -nP -iTCP:8792 -sTCP:LISTEN`
named the same process, `voice-flow` pid 1934, before the run and after it.

| File | What it is |
| --- | --- |
| `result-table.txt` | the printed table of the run from the bundle that carries the `localhost` transport-security exception |
| `result-no-exception.txt` | the same run from the bundle with no transport-security key at all |
| `result.json` | the same rows as data, for anything that wants to read them |
| `page.png` | the page as WebKit drew it, taken from the web view, which was never put into a window |

Both runs: 23 of 23 checks passed, exit status 0. The two tables differ only in the
directory named by the `page_snapshot` observation, and `result.json` differs from the
other run's only in that same line.

One line in the run's output is not from the proof and is not a failure:
`sandbox_extension_issue_file_to_process failed for /tmp/k7-proof/LoopbackProof-<variant>.app:
1 (Operation not permitted)`, printed once per variant between `codesign` and the table. It
comes from `codesign` ad-hoc signing a bundle under `/tmp`. Signing succeeded and both bundles
ran; no check is affected and the exit status is 0.

`page.png` is 2200 by 1648 pixels: the view is 1100 points wide and is resized to the page's
own height plus 24 points before the snapshot is taken, and this display draws two pixels to
the point. It shows the checks the page itself made, from `secure_context` to
`iframe_to_another_localhost_port_loads`, the page's own observations under them, and the
framed page from the other `localhost` port below the table.
The rows the native side made — `listens_on_*`, the four refusal checks,
`socket_without_ticket_refused_natively`, `page_loads`, `page_reported`, `rule_list_compiled`,
`upgrade_header_*` and `page_snapshot` — are in `result-table.txt`, because the page never saw
them.

What this does not cover: the real Voice Flow application, port 8792 and its `Info.plist`;
the interface bundle and its delivery; the page reaching `https://atika.ai` from
`http://localhost`; and the behaviour of the transport-security exception on macOS 14 and
15, which this Mac cannot run.
