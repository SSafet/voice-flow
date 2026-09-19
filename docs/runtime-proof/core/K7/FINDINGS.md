# K7 findings — what the running proof changes in the designs

Measured on 2026-09-19 on macOS 27.0 (build 26A428), Swift 6.4, from two application
bundles of the same program. Table and picture: `result-table.txt`,
`result-no-exception.txt`, `page.png`. Everything below is an observation first and a
recommendation second; where the two runs agreed, it says so. Both runs passed 23 of 23
checks and their tables are identical apart from the directory the `page_snapshot`
observation names, so every measurement below held in both.

## 1. The arrangement holds

A `WKWebView` loading `http://localhost:<port>/` from a Hummingbird server inside the same
program, bound on `127.0.0.1` and `::1`: the page loads, `window.isSecureContext` is true,
`crypto.subtle` computes a SHA-256 (32 bytes returned), `navigator.clipboard.writeText` is a
function, and `document.cookie` is empty. A data request carrying the per-launch header secret
is answered 200 and one without it 401; a request with `Origin: http://evil.example` and the
right secret gets 403, one with `Host: evil.example` gets 403, and a cross-origin preflight
gets 403. A one-use ticket fetched with the header opens one WebSocket, a second use of the
same ticket is refused, and a socket without a ticket is refused. Nothing in branches 02 §3.2,
02 §3.6, 06 §3.9 or ruling C9 needs to change because of this section.

## 2. The header secret cannot be injected by the native side; the page must send it

The design brief asked how a `WKWebView` can add a header to **every** request of the page.
The answer measured here is that it cannot. WebKit's only candidate mechanism, a content
rule list with the `modify-headers` action, compiles and installs (`rule_list_compiled`:
`modify-headers compiled`), and the same rule list's `block` action on a path under the same
filter does take effect — `rule_list_block_control` records
`GET /probe/ruled/blocked, which the rule list blocks: network-error: TypeError: Load failed`,
which proves the list is live. The header still arrives on none of the four request kinds
that were tried against paths the `modify-headers` rule covers, with the page sending no
header of its own:

| Request kind | What the run recorded |
| --- | --- |
| `fetch` | `ruled_fetch`: `GET /probe/ruled/fetch with no page-side header: 401` |
| `XMLHttpRequest` | `ruled_xhr`: `XMLHttpRequest /probe/ruled/xhr with no page-side header: 401` |
| `<script src>` sub-resource | `ruled_subresource`: `<script src=/probe/ruled/script.js>: refused` |
| WebSocket upgrade | `upgrade_header_probe_ruled_socket` and `upgrade_header_api_v1_threads_socket`: the server saw that neither upgrade request carried the `x-loopback-secret` header |

The socket under the ruled path did open (`ruled_socket`: `message:hello-ruled`) because that
route only records what the upgrade carried; it does not require the header. What it recorded
is the finding.

What works, and what the designs should say: the shell generates the secret at launch and
hands it to the page in the shell descriptor, injected by a `WKUserScript` at document
start, and the page puts the header on its own data requests. That is exactly what
02 §3.6 and 06 §3.9 already describe, and 02 §3.2 item 4 already states it as "Every request
other than the static files themselves carries it as a request header", with the interface
posting for the ticket and connecting with it. Both documents were searched on 2026-09-19 for wording that has the
native side adding the header to every request, and there is none, so nothing has to be
corrected here — but nothing should be written later that says it, because it does not work.

## 3. A sub-resource cannot carry the secret — `/shell-files/<id>` needs the other rule

A page cannot put a header on anything it loads by `src`: an `<img>`, a `<script>`, a style
sheet, a `<video>`. The proof shows a guarded `<script src>` being refused
(`subresource_without_secret_refused`: `<script src=/probe/guarded.js> refused; GET
/probe/guarded.js with the header: 200` — the same path fetched with the header is served,
so the refusal is the missing header and not a missing file).

Consequence, and a decision for branches 02 and 06: `/shell-files/<id>` — where a native
capability leaves a screenshot or a picked file for the composer (02 §3.7) — is listed in
06 §3.9 with the access rule "header secret". If the interface ever renders one of those as
an `<img src>`, it will be refused. Either serve staged files under the same rule 06 §3.9
already uses for attachment bytes ("a path plus an unguessable value, valid until the app
quits"), or require the interface to fetch them with the header and make a blob URL. The
first is simpler and already in the design for its neighbour.

## 4. The WebSocket cannot carry a header at all, so the ticket is not optional

The page's `WebSocket` constructor rejects an options argument outright —
`websocket_js_header_argument` records `constructor rejected it: SyntaxError: The string did
not match the expected pattern.` — and the rule list does not reach the upgrade either: the
server recorded that neither upgrade request carried the header. The ticket step that ruling
C9 already requires is therefore the only way a socket can be authenticated from a page, not
a convenience. It works: one ticket, one socket (`socket_opens_with_ticket`: `first socket:
message:hello`; `ticket_is_single_use`: `second socket with the same ticket: error`).

## 5. The transport-security exception was not needed on this macOS

The same program was run from a bundle carrying
`NSAppTransportSecurity` → `NSExceptionDomains` → `localhost` → `NSExceptionAllowsInsecureHTTPLoads`
= true, and from a bundle with no transport-security key at all. **Both runs passed all 23
checks**, including `secure_context`, and the two tables differ only in the directory the
`page_snapshot` observation names. On macOS 27.0, plain HTTP to the name `localhost` from a
`WKWebView` needs no exception.

Recommendation: keep the key anyway, in the narrowest form the master plan already fixes,
and stop calling it a requirement. `LSMinimumSystemVersion` is 14.0, this Mac cannot run
macOS 14 or 15, and the key costs nothing: it names one host, allows insecure loads for that
host only, and `NSAllowsLocalNetworking` stays unset. It is insurance for the older systems
the app claims to support, and this is now a measured statement rather than an assumption.

## 6. A frame pointing at another `localhost` port loads and runs

Branch 06 §3.10 has the Preview pane load `http://localhost:<port>` directly. A frame
pointing at a second server on another loopback port loaded and its script ran, answering
the parent by `postMessage` (`iframe_to_another_localhost_port_loads`: `iframe of
http://localhost:8798/: the framed page ran and answered`). Branch 06's validation item 1 can
keep that clause.

## 7. Refusal statuses, for whoever writes the real loopback server

Measured: no secret → 401; foreign `Origin` → 403; wrong `Host` → 403; cross-origin
preflight → 403; WebSocket upgrade without a ticket → **400**, not 401, from a route whose
ticket check throws `HTTPError(.unauthorized)`. The 400 is Hummingbird's doing: when the
`shouldUpgrade` decision throws, the upgrade attempt is answered as an ordinary HTTP request.
If branch 06 wants the socket path to answer 401, the ticket has to be checked before the
upgrade decision rather than inside it.

A second consequence of that 400, for whoever writes the tests — measured while this proof was
being built rather than by the run recorded in the two tables, and written down at
`proofs/loopback-webview/Sources/LoopbackProofCore/NativeChecks.swift:120-132`: an upgrade
request to a path with no socket route at all is answered `400` with an empty body too, byte
for byte the same answer. A test that reads the status alone cannot tell a refusal from a route
that is not mounted. This proof's native row pairs the refusal with a handshake that must be
answered `101` using a ticket minted over the guarded route, which is what makes it evidence.

## 8. `window.Notification` exists in a `WKWebView`; nothing has to be explained away

`window.Notification` is present with permission `default`, and `navigator.clipboard` is
present. Neither is needed — the interface notifies through the shell bridge's `notify`
capability (02 §3.6, 02 §3.7) — but the design no longer has to hedge about them.

## 9. Two small corrections to the plan documents

- The master plan's K7 entry says this work owns `tests/loopback_probe/**`. It lives in
  `proofs/loopback-webview/`, as its own Swift package, kept out of the app's build. One of
  the two should be corrected; the folder here is the one the design lead asked for.
- The master plan's K7 entry says this package delivers "a bare window with a `WKWebView` loads `http://localhost:8792/`". Neither half was done, on purpose. The web view is never put into a window, because an agent has to be able to run this unattended and a window would wait for a person; the picture is taken from the view itself with `takeSnapshot`, which is the same rendered page. And the port is 8799, not 8792, because the owner's daily Voice Flow build holds 8792 on this Mac and this work does not touch it — the arrangement proved is "a fixed port, the host name `localhost`, both loopback addresses", which 8799 exercises exactly as 8792 would. Whoever keeps the master plan should reword that entry so a later reader does not think the window and the number were requirements that were missed.
- The master plan's Global Constraints put every package's evidence under
  `docs/architecture/runtime-proof/<area>/<package id>/` in the Atika repository. K7 runs
  in the VoiceFlow repository, and its evidence is here, in that repository's own
  `docs/runtime-proof/core/K7/`; the Atika-side copy is text in the report to the design
  lead. Whoever keeps the master plan should say which of the two folders holds evidence
  for work packages whose repository is VoiceFlow.
- `hummingbird-websocket` 2.7.0 declares `platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17)]`
  and requires `hummingbird` 2.24.0 or newer; 2.26.0 is the newest hummingbird release
  (2026-07-29). This confirms the master plan's floor of `LSMinimumSystemVersion` 14.0, which
  the app's own `Voice Flow.app/Contents/Info.plist` — tracked in this repository — still sets
  to 13.0 (checked on 2026-09-19; that file has no transport-security key at all today). K8
  changes it. Nothing in K7 edits that file.

## 10. What K7 did not measure

The real app on port 8792; the interface bundle and its static delivery; the page reaching
`https://atika.ai` from `http://localhost` — the Mac shell's second endpoint, which needs a
deployed gateway and belongs to W3's sign-in work; and macOS 14 and 15, which this Mac
cannot run.
