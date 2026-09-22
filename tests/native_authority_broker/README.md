# Native authority broker proof and composition

The production closure is `T3NativeAuthority.swift`, `T3NativeAuthorityBroker.swift`
and the small `T3EnvironmentProcess` extension. Hummingbird **2.26.0**, already pinned
by the app, owns HTTP parsing, the ephemeral listener, channel lifecycle and request
body collection. The optional tools mount uses the already-pinned official MCP Swift
SDK **0.12.1** HTTP request/response types. Security generates the 32-byte launch capability; CryptoKit compares
fixed-length capability digests. This adds no dependencies, credential store, proxy,
custom MCP implementation, account creation, or environment runtime.

## Owner wiring

1. Capture the approved signed `T3EnvironmentProcess` and the **existing** native
   credential-owner actor. Do not instantiate another `CloudHTTPClient` or select
   an account/home from request fields.
2. Construct `T3NativeAuthorityBroker` with these required closures:
   - `ownedEnvironment()` calls the process's `authorityEnvironmentIdentity()`.
     It takes no caller-supplied ID. Its result contains the persisted T3
     `environmentID` and a native per-launch `generation: UUID`.
   - `leaseProvider(environment)` calls that same native owner's
     `runtimeCredentials(for:)`, with the approved `CloudRuntimeBinding` and the
     supplied exact environment ID/generation. Map native `identity.generation.uuidString`
     unchanged to `binding.identityGeneration`, `identity.origin` to `gatewayOrigin`,
     and the returned native token/expiry to `T3NativeAuthorityLease`. No token cache.
   - `isCurrent(lease)` delegates to the native actor's `isCurrent(_:for:)` against
     that exact binding. This runs after renewal and again after the awaited
     ownership check. It must not simply compare the request body or a saved flag.
3. `await broker.start()` yields `T3NativeAuthorityBootstrap`; pass it only to
   `process.start(nativeAuthority:)`. The adapter sends it in the existing inherited
   stdin envelope, never arguments, environment variables, files or renderer config.
4. Native account/home/generation invalidation must call `broker.invalidate()`.
   The native owner should complete that revocation before continuing a changed
   account lifetime. Child exit/start failure and application quit must call
   `await broker.stop()`. Root App composition owns those hooks; they are not
   installed by this branch. A stopped/revoked broker cannot restart.

The ownership read works before `server-runtime.json`/HTTP readiness so provider
hydration cannot deadlock startup. It requires the captured running process, held
home lock, matching home/lock inodes, owned non-writable-by-others directories and a
regular no-follow identity file. The first read pins that ID; a replacement ID,
FIFO, symlink, stopped process or different launch cannot supply authority.

## Exact private wire

`POST /v1/authority/lease`, `Content-Type: application/json`,
`Authorization: Bearer <43-character unpadded base64url launch capability>`.

Request: `{environmentId, expectedBinding?: {ownerId,deviceId,homeId,identityGeneration}}`.
Response: `{version:1,binding:{ownerId,deviceId,homeId,identityGeneration},gatewayOrigin,accessToken,accessTokenExpiresAt}`.
Expiry is ISO8601 UTC with milliseconds. IDs and UUID spelling are preserved.

The listener binds only `127.0.0.1` and chooses an ephemeral port. Host must match
that exact numeric authority. Origin, Referer, Cookie, fetch metadata and duplicate
authentication/Host fields are refused before ownership/credential access. There
are no CORS headers, redirects, request logs or diagnostic response causes.
Request bodies are capped at 4 KiB, responses at 32 KiB, tokens at 16 KiB, active
authorized requests at 16 and connections at 32. HTTP headers and idle time are
also bounded. The default request deadline is 10 seconds; tests can inject a
1 ms–60 second deadline. The sole error body is
`{"error":"Native Atika authority is unavailable."}`.

The first valid response pins binding + gateway origin. Expected-binding conflicts
return 409, untrusted HTTP/environment selection returns 403, unavailable/invalid
leases return 503. Loss of established ownership, identity/origin/launch change,
or failed post-renewal current checks permanently revokes the launch. Initial
absence of an identity file remains unavailable until the owned child establishes it.

HTTP disconnect cancels only that request. Hummingbird enables remote half-close;
a SwiftNIO input-EOF handler closes this private request/reply connection immediately
so a cancelled client cannot leave native work parked until its execution deadline.
Native invalidation and stop cancel all
pending work and release HTTP waiters, including when a fixture provider ignores
cancellation. A delayed provider result cannot publish afterwards. Already published
responses cannot be recalled; this is a response-publication boundary, not network
delivery acknowledgement or remote JWT revocation.

## Optional native tools mount

`T3NativeAuthorityBroker.ToolsMount` takes an official SDK handler
`(MCP.HTTPRequest, T3AuthorityEnvironmentIdentity) async -> MCP.HTTPResponse`, a
synchronous `revoke()` closure and an asynchronous `stop()` closure. Root maps the
trusted environment value to `T3NativeToolEnvironment(environmentId:launchGeneration:)`
for the native tool service. That service owns current native identity/policy checks,
preflight, exact one-use execution authorization and primitive checkpoints. No
request metadata can replace the trusted environment argument.

When configured, only `POST /v1/tools/mcp` is added to the existing listener. It
shares capability/Host/Origin/query/header checks with leases and verifies the owned
child before **every** handler admission and again after the awaited handler. The
launch Authorization header never enters the SDK; only Accept, Content-Type,
MCP-Protocol-Version, MCP-Session-Id and Last-Event-ID are passed. The SDK still owns
JSON-RPC parsing, version negotiation, dispatch, errors and notification semantics.

Tools have a separate **120-second** deadline, configurable within 1 ms–10 minutes,
a **96 KiB** request limit and a **7 MiB** response limit, sufficient for twelve
400,000-byte images encoded as base64 plus JSON. These settings do not change lease
limits. SDK JSON errors and `202` empty notification responses are preserved.
Streaming responses explicitly fail with `501`; SSE-only Accept requests are rejected
by the stateless SDK. No service-supplied CORS, cookies, redirects, credentials or
other response headers cross the mount. Responses are JSON, no-store, connection-close.

Broker invalidation calls native `revoke()` synchronously **before** cancelling
work/releasing HTTP replies. Shutdown then awaits native `stop()`, exactly once.
Per-request deadline/disconnect only cancels that handler Task; it does not revoke
the whole launch. A changed lease identity or changed/lost owned child revokes both
routes and pending tool work. With no mount, tools remain unavailable (`404`).

## Execute

`bash tests/native_authority_broker/test.sh` builds only Hummingbird/MCP dependency
target and compiles the actual production broker files into a temporary proof.
`VOICE_FLOW_TEST_SPM_BIN=/absolute/pinned/build/Products/Debug` can reuse an existing
dependency build without mutating it. No app executable is built or launched.

`bash tests/t3_native_shell/process.sh` separately compiles/signs synthetic process
fixtures and verifies stdin exclusion, identity-before-readiness, source preservation,
ownership rejection and exact child lifecycle. All fixture files are temporary.

Remaining integration gates: root-owned App lifecycle and same-native-actor binding,
the packaged T3 client against this broker, combined app build/signature, and deliberate
account/home changes during a real launched environment. The optional mount is tested
against the real official SDK plus isolated native-handler fixtures; final composition
with the actual native tools service remains root-owned. No real
credentials, Keychain, GUI, daily data, gateway inference or paid calls were used.
