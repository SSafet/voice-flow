# Owned-child native tools v1

Inactive library component; App composition and the private broker mount are separate. `T3NativeToolMCP` uses the official MCP Swift SDK `Server` and `StatelessHTTPServerTransport`. Mount only behind the owned-child broker's capability, exact Host/Origin, current identity, and current child checks at `POST /v1/tools/mcp`. No public MCP session or legacy picker/session is created. Broker supplies the owned environment independently of JSON. The renderer/model must never receive the broker credential or execution tokens.

```ts
interface Binding {
  environment: { environmentId: string; launchGeneration: string }; // UUID
  ownerId: string;
  deviceId: string;
  homeId: string;
  identityGeneration: string;
}
interface Manifest {
  version: 1;
  binding: Binding;
  revision: string; // lowercase SHA256 of binding + backend/policy revisions + actual SDK Tool catalog
  backendRevision: string;
  policyRevision: string;
  tools: Tool[]; // official MCP Tool
}
interface NativeCall {
  threadId: string;
  turnId: string;
  callId: string;
  tool: string;
  arguments: Record<string, unknown>; // JSON, <= 64 KiB
  manifestRevision: string;
}
interface Preflight {
  version: 1;
  decision: 'allow' | 'ask' | 'deny';
  callDigest: string; // opaque lowercase SHA256, excludes UI review text
  review: string; // <=4096 UTF-8 bytes; secret-bearing content explicitly [redacted]
  requestId?: string; // native request ID; bind privately to T3's durable approval ID
  executionToken?: string; // present only on allow, private one-use capability
}
```

`tools/list` is standard MCP: `{tools, _meta:{"ai.atika/nativeManifest": Manifest}}`. Validate the full native binding against the lease/current environment before admitting a turn. Pin `launchGeneration`, revision, backend and policy for that launch. Do not reconstruct or guess a native policy revision from a schema hash.

Custom official SDK methods:

| Method | Parameters | Result |
|---|---|---|
| `voiceflow/native/preflight` | `{version:1, call:NativeCall}` | `Preflight` |
| `voiceflow/native/approve` | `{version:1, call:NativeCall, requestId:string, decision:'allow-once'\|'reject'}` | `Preflight` |
| `voiceflow/native/closeTurn` | `{version:1, threadId:string, turnId:string}` | `{version:1, closed:true}` |

Preflight never effects the Mac. An exact duplicate returns the same pending ID or unconsumed token. Changed arguments, consumed calls, expired capabilities, stale revisions or closed turns refuse. Each approval response is atomically consumed: contradictory/duplicate answers cannot grant twice. The native `review` is safe for durable approval display; never persist raw secret-bearing arguments as review details. Native denial always wins over a T3 runtime mode. An `allow`→`ask` restriction change invalidates a capability issued without human approval.

Execute through standard MCP `tools/call`:

```ts
{
  name: call.tool,
  arguments: call.arguments,
  _meta: {
    'ai.atika/nativeCall': {
      version: 1,
      threadId: call.threadId,
      turnId: call.turnId,
      callId: call.callId,
      manifestRevision: call.manifestRevision,
      executionToken: preflight.executionToken
    }
  }
}
```

The server recomputes the full call digest and consumes the capability before awaiting or performing any effect. The client should consume its local token before dispatch too. **Never automatically resend an ambiguously dispatched native call**, including with a new call ID. A transport error may follow a committed effect; present uncertainty and reconcile it explicitly. MCP result `isError` is truthful; native exceptions return safe error codes, not raw arguments or file paths.

Native grants expire after ten minutes. Per launch, at most 4096 active call records and 4096 closed-turn markers are kept; capacity exhaustion refuses admission rather than evicting executable tombstones. `closeTurn` permanently closes that scope, revokes running checkpoints and frees individual call records. Its required `onTurnClosed(threadId,turnId)` host callback clears `T3NativeToolPrimitives` screenshot geometry. New launches mint new bindings. `revoke()` is synchronous; `stop()` revokes then awaits SDK shutdown. Broker cancellation is carried into the SDK-dispatched call via a per-request lifetime; standard MCP cancellation also cancels SDK tasks. Checkpoints run before effects, between CGEvents and after asynchronous reads. An interrupted mouse/key-down sequence emits only its required release cleanup.

## Host inputs and services

Construct `T3NativeToolPrimitives` with existing services, then `T3NativeToolService` with its `execute` closure and an authority closure. Authority must be derived from the actual owned child, verified credential-owner identity and current native restrictions, and must validate each call's active thread/turn ownership. Missing authority returns `nil`. Every checkpoint rechecks binding, backend revision, policy revision and action permission. Supply a real native build/protocol revision and a configuration revision for relevant permissions/grants; there is no permissive default. Personas, budget admission, canonical transcripts and user questions remain T3/gateway-owned.

`T3NativeDeviceAdapters` provides existing `ScreenCapture` + `ComputerControl`, `OverlayManager`, and `CapturedIndex` + `CapturedReadService` adapters without launching services. Construct only the tool families whose backend is connected. Existing native computer-control settings and Accessibility permission are independently checked at every CGEvent. Screen recording permission is checked without prompting. T3's active thread overlay owner is `T3NativeToolPrimitives.overlayOwner(binding:threadId:)`; App must select that explicit owner for rendering, never a legacy picker identity.

## Tool semantics and bounds

- `voiceflow_computer`: actual JPEG image blocks, <=400,000 bytes, advertised width/height and opaque `screenId`. Coordinates reference that exact encoded image and map to Quartz global points, including other-display origins. Drag accepts both `start_coordinate` and `coordinate`. A newer screenshot invalidates the prior screen ID; changed display geometry refuses. Type/key content is redacted in reviews. Wait <=5s, text <=4096 UTF-8 bytes, scroll <=30 lines. Latest frame only per active turn; max128 active turn geometries.
- `captured_search`, `captured_get`, `captured_frames`, `captured_around`, `captured_summary`: reuse established CapturedReadService schemas/limits and no-follow file ownership. Pictures are MCP image content with `ai.atika/captureId`, width and height metadata. Authorization is checked between image reads and before returning any result. Private, absent, redacted and unavailable states remain domain results. Original sources are not changed.
- `voiceflow_overlay`: existing guide/panel/annotation file primitives scoped to T3 owner and thread. IDs are opaque safe storage names; returned data contains no native paths. Payload <=64KiB; list <=100. Annotation requires the latest `screenId` and transforms coordinates to the existing OverlayManager space, selecting that display. Panel/guide placement accepts a named anchor. Root still owns selecting/rendering the active T3 overlay owner.

No native questions, reports, inbox, queues, memory, scheduler, TTS auto-play or alternative draft store are advertised. Captured images and screenshot images require the T3 host to convert official MCP image blocks to its existing native user-parts seam; source/history input attachments remain governed by T3 admission separately.

Use one shared official MCP client per owned launch, with its increasing request IDs for all parallel turns. The stateless endpoint has one request-ID namespace; concurrently reused IDs (including numeric/string aliases) refuse409. There is no multi-client session multiplexing.

HTTP envelope <=96KiB; broker response <=7MiB. Broker default native deadline120s (configurable up to10min), separate from lease deadline. The service exposes no listener, credentials or generic file access.
