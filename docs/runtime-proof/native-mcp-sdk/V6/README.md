# Native MCP SDK source receipt (V6)

Source: `22c5c69bb0ba68a71833300695333af492c018c9`, isolated `codex/native-mcp-sdk`, based on platform `a486be9`. All source checks passed on 22 September 2026. Production/source and fixture hashes remained unchanged across execution; see `execution.json` and `source-manifest.json`.

| Executed boundary | Result |
| --- | --- |
| `tests/native_mcp_sdk/test.sh` | 46 checks passed; 13.820 s including compile. Real LocalAPIServer socket + official SDK server/client and legacy JSON shape. |
| `tests/native_mcp_sdk/captured.sh` | 132 assertions passed; 16.062 s including compile. Actual GRDB FTS5/derived source index, native image processing and SDK result/host path. |
| Existing `--unit --only inbox` | Passed; 2.736 s. Existing supersession/deletion/routing regression suite. |
| Native App/App+MCPTools/TTS/LocalAPI parse | Passed; 0.058 s. Parsing is not full app typechecking/build. |
| `git diff --check` | Passed. |
| License template staging copy | Unchanged upstream MCP and EventSource notices survived copying the existing app template; hashes in `license-copy.json`. No app was installed or launched. |

The HTTP proof covers supported revision preservation and SDK negotiation, 15 retained + 5 captured tools, invisible/named session identity, anonymous and restarted callers, concurrent waits, same request ID in different sessions, duplicate in-flight ID refusal, cancellation notification, official SDK cancellation, TCP disconnect without DELETE, DELETE cleanup, refresh, hostile Origin on POST/DELETE, malformed RPC and all TTS endpoint callbacks. Four-hour question **configuration** uses the production cancellation primitive with a synthetic handler and is cancelled promptly. A separate clock test proves an active voice identity survives four hours and expires only after its subsequent idle lease. Neither test is a four-hour wall-clock soak or a native AppKit question interaction.

The captured proof uses the production `MCPServer.readCaptured` path. Unconnected authority is explicit; another peer cannot gain access from a supplied threadId/_meta claim; a synthetic caller grant enables the real query and image result; withdrawal stops later reads and between-metadata/image revocation returns no image. Structured output, image captureId/decoded geometry, 400 KB image/4.8 MB result limits, appended-hint preservation and PEM redaction are checked. The original S2 preservation/query assertions remain in the executed closure, including source SHA equality. This synthetic authorization fixture does not implement the missing device-channel grant authority.

## Integration remaining

- Root's combined app build and signed native acceptance: actual report/question UI, targeted reply/attachment handling, overlay create/update/list/clear with two sessions and the user's own marks.
- Current Claude Code and Codex external clients plus meaningful held-call duration/refresh; the advertised `vf` executable is absent on this host. The app now reports this unavailable listener and directs the caller to `wait_for_message`. A fixture with an executable preserves the old attach command but does not prove that external script.
- Real authenticated device-channel/allowed-client observe-grant resolution and tunneled captured tools/images. Default is denied; locality, the assistant dial and caller-supplied fields are not authority. This gate remains open.
- Shared registry/runner inventory: legacy e2e currently expects exactly 15 tools; it must register the five additional schemas and include `MCPCapturedCatalog.swift` in catalog source discovery.
- Source move: LocalAPI/TTS payload now compile from `LocalAPI.swift`; source-list-based consumers must include it. Only root should perform the integrated build/install gate.

## Retirement accounting

Removed: 100 lines of the old custom MCP request dispatcher/error envelope section. Moved: 378 original LocalAPI lines + 8 TTS payload lines; these 386 lines are **not** deletion savings. New SDK adapters/cancellation/grant-bound query exposure and tests are additional code. This branch does not claim a net line reduction. SDK version/revision and all transitive pins are in `Package.resolved`; no SDK source fork or new HTTP server was introduced.

The MCP upstream license text is retained exactly as shipped: it describes an Apache-2.0/MIT transition and CC-BY-4.0 documentation. The new transitive EventSource notice is MIT. Both full notices live in app-template `Contents/Resources/ThirdPartyNotices`, so the existing installer copies them before signing.
