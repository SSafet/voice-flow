# S2 query and retrieval proof — 22 September 2026

**Source:** `dc1132d` in `/Users/safet/repos/voice-flow-captured-query`.

**Integrate:** cherry-pick the query commit and this evidence commit. Its local parent `9de9787` copies only the exact four helper files from platform `805e9a3`; platform already has those moves. No App, runtime, generated contract, watcher, pending-audio or captured-service lifecycle file was changed by the query commit.

**Passed:** `tests/captured_query_service/test.sh` compiled the entire production captured source closure and passed **115 assertions**. The final runner uses the shared extracted `AgentSecretPolicy.swift` and `ImageUtils.swift`, not assistant or capture lifecycles. An earlier run with their original source locations also passed 115 assertions. Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64 macOS; GRDB 7.11.1 and system SQLite FTS5.

The cases exercise prefix/AND FTS, stable pagination/collapse, filters/links, title/secret/context/marks handling, text continuation, UTF-8 result size, 1,100-child previews and child limits, private ancestor and password-manager exclusion, revoked observe access, rebuild progress, safe original file access, missing/thinned-source behavior, missing recordings, permission-denied errors, native thumbnails/crops, actual compression of a noisy image larger than 400 KB, image count/order/total size, clipped summaries, midnight splits and the repeated hour of a 25-hour DST day. Two synthetic image originals remain byte-identical after reads, compression and local derivatives; temporary files explicitly removed by missing-source tests remain historical index rows.

**SDK fit:** the pinned official Swift MCP SDK `a0ae212ebf6eab5f754c3129608bc5557637e605` passed **84 tests in seven suites**. This includes its tool, version, cancellation, stateful/stateless HTTP and handler-context suites plus `CapturedSDKAdapterProbe`. The added probe maps an actual service reply into the SDK's structured content, identical text content and JPEG image blocks with capture id metadata. It checks exact `2025-06-18` negotiation and preservation of caller thread metadata. The final source's synthetic reply matches the SDK-tested fixture byte for byte.

```sh
VF_CAPTURED_QUERY_FIXTURE=/tmp/vf-s2-sdk-fixture.json \
  bash tests/captured_query_service/test.sh
VF_CAPTURED_QUERY_FIXTURE=/tmp/vf-s2-sdk-fixture.json \
  bash tests/captured_query_service/sdk-probe.sh
```

The SDK script creates its own temporary checkout by default; an existing isolated checkout is accepted only at the pinned revision. It adds a temporary SDK test and removes it afterward. The native suite always chooses a new temporary config root. Both commands exited zero. [execution.json](execution.json), [query.log](query.log), [sdk.log](sdk.log) and [source-manifest.sha256](source-manifest.sha256) record the receipts and source boundaries.

**Not claimed:** no daily data, live watcher/screen recording, installed app, model call, public server, full optimized app build or signed app gate was used here. Root owns the combined app build and integration. SDK tests do not establish compatibility of current clients' long-held ask/wait calls, durable external-thread targeting or live tunneled approval/revocation. Those remain V6/L6 cutover gates.

The consumer work still required is one authenticated host/SDK registration and one shared-client route to this service, correct owner/tool limits and observe decisions, image metadata attribution over the real device channel, and actual original/thumbnail/missing/private/denied client flows. Full health, recording delivery/retry, retention, text attachment packaging and background OCR require their actual owner state/services. This branch deliberately adds no second server or fake lifecycle state. [The integration record](../../../../design/captured-query-integration-2026-09-22.md) defines those boundaries and the OSS decision.

## Central private-key policy follow-up

After platform's central `fa6c381` policy fix (local cherry-pick `6eb4074`), the same reduced production closure passed **119 assertions**. Three additional checks go through real query replies: a complete PEM block longer than the text window, a search hit whose indexed body contains that key, and an interrupted PEM block. No PEM body/footer escapes; surrounding prose remains for complete blocks. There is no duplicated query-specific secret policy.

A fourth regression verifies `.urlHost` with both a full `https://person:pass@example.com/...?...` URL and a stored `example.com/...` form. Both group into `example.com`; `ContextRules.storedURL` removes scheme, credentials, query and fragment before grouping. No query implementation change was needed.

[pem-execution.json](pem-execution.json), [pem-query.log](pem-query.log) and [pem-source-manifest.sha256](pem-source-manifest.sha256) record this later snapshot; the original manifest remains historical evidence for `dc1132d`. The resulting image reply still matches the already-executed SDK fixture byte for byte, so the SDK suite was not repeated. Platform already has `fa6c381`; integrate only the query test/evidence follow-up, not its local helper cherry-pick.
