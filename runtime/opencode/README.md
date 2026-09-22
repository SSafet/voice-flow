# OpenCode v2 runtime

Voice Flow targets the exact **2.0.12** server and native plugin contracts.
`versions.json` pins the official `@opencode/cli-darwin-arm64` and
`@opencode/cli-darwin-x64` npm tarballs. Both published SHA-512 integrities were
verified before recording the archive and executable SHA-256 hashes. These are
v2 packages; the old GitHub `releases/latest` channel still advertises v1.

`prepare-opencode-runtime.sh` verifies the tarball and executable before copying
into a staging bundle. It extracts only `package/bin/opencode`, runs no npm
lifecycle scripts, and accepts the v2 `opencode v2.0.12` version output. Signing
seals the installed executable as before. Developer fallback binaries must match
the same reviewed hash. Legacy staged v1 and unreviewed newer binaries cannot
replace the pin. V2 updates ship with Voice Flow until a newer pair of runtime and
integration contracts has been reviewed.

## Isolation and native integration

The supervised process retains a real project/assistant working directory and
kernel-enforced filesystem/network restrictions. Its home, config, XDG data,
cache, state and temporary paths are private under `runtime/opencode/<profile>/v2`.
The legacy v1 native database is left untouched. It receives only rotating local
model-gateway/tool tokens, never provider credentials from Keychain.

V2 removed `--pure`. The checksum-verified 2.0.12 CLI maps
`OPENCODE_CONFIG_PROJECT_DISABLE=true` to the official server's
`config.project=false`. `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG_CONTENT`, private
`HOME` and `OPENCODE_TEST_HOME` supply the app-owned configuration. This suppresses
ambient project configuration/plugins while keeping native filesystem and shell
tools in the selected directory. This behavior is covered by a real hostile
project config and executable plugin fixture in `opencode_live_turn`.

V2 Basic authentication uses the fixed username `opencode`. `/api/info` reports
identity/version, not plugin readiness. The adapter waits separately for the
private plugin and configured-provider plugin to become active.

`AgentToolProjection` writes one dependency-free Promise plugin into the private
config's `plugins/voiceflow.js`. V2 accepts a plugin object and JSON Schema tool
inputs directly, so the old plugin/Zod SDK archive and npm dependency links are
removed. Six first-party tools remain native tools (`codemode:false`); requests
forward cancellation and return the v2 `{content}` result. No tool token is
written to a project or persona folder.

Selected skills come from the app's validated skill store through an authenticated
plugin RPC. Native skill IDs are scoped to the runtime session, and session
permissions deny every other skill ID. Cleanup removes them after each turn;
generation checks prevent a late cleanup from deleting a newer turn's catalog.
Unrelated session permissions are preserved.

## Transcript, stream and approvals

The Swift client uses v2 `/api` routes. A prompt response is durable admission,
not completion: the client waits for execution, checks the terminal outcome, then
reconciles the paginated native transcript back to that exact prompt ID. User
instructions use a separate API-managed instruction entry. Model selection uses
v2 `Model.Ref` (`providerID`, `id`, optional `variant`). Model readiness is checked
against the native catalog; an unsupported effort falls back to provider default
with an explicit activity message. Images use data-URI
file attachments.

SSE is volatile in v2. Explicit text deltas are reconciled with full-text boundaries,
and pending approvals are polled while the turn waits so a lost stream cannot
hide a permission request. Approvals use v2 action/resource fields and the native
session permission reply API. Stop interrupts execution and retains supervised
process-tree cleanup. Old v1 runtime bindings reseed from Voice Flow's canonical
history. A native session in another directory is also reseeded.

## Verification

Focused suites: `agent_tools`, `opencode_http`, `opencode_runtime`,
`opencode_updater`, and `fake_openai_server` via
`./scripts/test-agent-harness.sh --unit --only SUITE`.

The `opencode_live_turn` and `opencode_supervisor` probes run the actual pinned
binary in an isolated configuration root, with a local deterministic provider.
They assert all six native Voice Flow tools and native shell/skill on the first
cold provider request, plus real text/native-tool/selected-skill/image turns,
approval reject and allow-once, hostile ambient discovery, skill cleanup,
private credentials, concurrent startup, restarts and child-process cancellation.
The full live gate also runs the other product tests; focused results are not
full-gate evidence. Actual OpenRouter paid-model calls and installed-app UI QA
remain separate acceptance checks.

Contract sources: [migration guide](https://opencode.ai/v2/docs/migrate-v1),
[plugin API migration](https://opencode.ai/v2/docs/build/plugins/migrate-v1),
[HTTP API](https://opencode.ai/v2/docs/api), and the integrity-verified published
`@opencode/{client,server,protocol,schema,plugin}` **2.0.12** package sources.
