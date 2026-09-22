# Native host for the selected T3 client

This is the bounded host implementation for the platform 00/14 whole-project
decision. It adds a normal AppKit window around the actual local T3 client. It
does not make the earlier native thread-store recovery branch a second owner.
No legacy shell, runtime, storage, UI, capture, dictation or speech code is
deleted or replaced here. Root integration owns the eventual cutover.

## Integration contract

`T3ShellWindow` receives an approved local `T3ShellOrigin`, its expected
environment ID, a dedicated `WKWebsiteDataStore(forIdentifier:)`, an explicit
content-rule-cache URL under app-owned storage, and only the native capability
callbacks actually available. The default shared WebKit store is refused.
QA uses a nonpersistent store after the earliest-entry launch guard.

Call `attach(credential:)` once with the upstream bootstrap credential. Native
URLSession is ephemeral, has no cookie storage, and refuses redirects. It
checks the environment descriptor, discovers the session-cookie name through
`/api/auth/session`, then calls the existing `/api/auth/browser-session` API.
Only its validated host-only, HttpOnly, expiring cookie enters WebKit before
navigation. No provider credential or bootstrap token enters renderer state.
Capability/authority scopes remain those issued by T3; the native bridge does
not expand them.

The client namespace and exact wire types are in `web/voiceFlowShell.ts`.
`window.desktopBridge` stays absent, so the web client uses its normal cookie
HTTP and WebSocket transport. Root integrates the consumer through T3's
existing draft APIs and existing auth-supervisor wakeup; there is no new native
connection supervisor or canonical protocol package.

After `describe()`, the mounted composer publishes its exact target and the
current document ID. `composerId` changes when a composer is remounted. Native
hotkey capture freezes that target at start, then calls `deliver` using the same
stable delivery ID throughout reconciliation. `accepted` means the web consumer
has durably written the exact draft and recorded the delivery ID. Native source
bytes remain owned by the existing capture/dictation service until that receipt.
Wrong target returns `stale-target`; no handler returns `unavailable`; malformed
input returns `rejected`. Timeout, bad receipt, promise rejection or renderer
loss returns `unconfirmed` because an effect could already have committed. Never
discard the original, retarget it, or auto-send a turn on any failure. Reuse the
ID on a deliberate retry; the shared draft owner must deduplicate it durably.

Capture IDs are opaque references, never native file paths. Until root connects
the existing capture lookup/upload flow, the shared consumer must reject any
input with capture IDs rather than accepting only its text. Native callbacks
drive the existing dictation, capture, speech and settings services. The host
advertises no callback absent from its constructor.

`renewCredentials` is explicit auth renewal, not the socket-retry path. It
installs the replacement cookie then invokes the registered credentials-changed
consumer. It does not reload, clear the draft or retry any send. Root owns secure
credential retention/expiry triggers/account retirement. T3's client-runtime
continues to own reconnect, reachability, cached projections and offline UX.

## Native boundaries

Bridge messages must come from the main frame, exact origin and permitted T3
application route. Authenticated file/API routes cannot become the privileged
main document. HTML preview responses require an opaque CSP sandbox; PDF must
have the real PDF MIME type. Other-origin subframes, including alternate
loopback ports, are refused. Cookie content rules additionally strip cookies
from every other origin for subresources; host-only cookies alone do not isolate
ports. This rule must be measured in real WebKit before cutover.

The selected client already uses an opaque iframe sandbox for HTML and the
server emits an opaque CSP sandbox for HTML/SVG. The host adds response gates
instead of trusting a filename. Local blob HTML without a response CSP and
remote-environment document frames are currently refused. Their native preview
adapter remains an integration gap; do not claim full preview parity. Arbitrary
project websites require a separate unprivileged browser store/host. External
user links open through NSWorkspace without reusing the privileged WebKit
store. New-window actions never create another privileged view.

Standard WK open/save delegates preserve the shared client's attachment chooser
and download actions. A preview cannot invoke the native open panel, a download
cannot follow a cross-origin redirect, and a suggested name cannot choose a
native path. Save destinations remain explicit system-panel choices. These
delegates are compiled, but interactive chooser/save behavior is not yet proved.

Window close hides it. Explicit app/account/environment shutdown removes bridge
handlers, cancels native downloads/open panels and invalidates outstanding input
receipts. It does not kill the attached environment. A renderer failure invalidates
its composer targets and offers an explicit retry; it never replays inputs. Saved
T3 drafts own restoration, not a second native draft store.

## Validation boundary

Run `VOICE_FLOW_TEST_PYTHON=/path/to/repo/.venv/bin/python bash
scripts/test-agent-harness.sh --unit --only t3_native_shell`. The suite checks
origin/path/preview rules, frozen targets, real wire serialization, isolated
URLSession bootstrap using URLProtocol, actual injected JS in Node, safe whole
archive staging and all host source compilation against the public macOS 14+
SDK. It verifies fixture guard ordering in source. Registry/evidence tests cover
the new suite and source fingerprinting of the bridge and fixture.

`proofs/t3-native-shell/build.sh` builds and ad-hoc signs a standalone host only.
No UI, environment server, model request, installed app, daily data or final
App wiring has been exercised by these checks. The root coordinator owns the
one guarded run against its final shared-client bundle. Live cookie/WS behavior,
renewal/offline preservation, actual native services and model/budget authority
remain unproved until that run and their separate integration gates finish.
