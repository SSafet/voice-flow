# Real Swift native-tools fixture

This test executable composes the production `T3NativeAuthorityBroker`, `T3NativeToolMCP`, `T3NativeToolService` and `T3NativeToolPrimitives`. Its authority and computer device closures are synthetic; it never posts CGEvents, reads the screen or Keychain, creates App/legacy sessions, or invokes a provider. It advertises only `voiceflow_computer`. The first executable statement applies the existing `QALaunchIsolation` guard; absent/unsafe `VOICE_FLOW_CONFIG_ROOT` exits78 before paths/services/sockets.

Build only (no app build/install):

```sh
VOICE_FLOW_TEST_SPM_BIN=/path/to/pinned/.build/out/Products/Debug \
  python3 tests/t3_native_tools_fixture/build.py /absolute/output/fixture
python3 tests/t3_native_tools_fixture/smoke.py /absolute/output/fixture
```

Without the dependency path, build.py builds only pinned MCP/Hummingbird/GRDB targets. Launch with a fresh absolute isolated config root and private stdin/stdout/stderr pipes. The listener binds127.0.0.1 port0. First stdout line is **private bootstrap**, not a log:

```ts
{
  version: 1,
  nativeAuthority: { origin: string, credential: string },
  environmentId: string,
  launchGeneration: string,
  binding: { ownerId: string, deviceId: string, homeId: string, identityGeneration: string }
}
```

Do not print, persist, expose to the renderer, or include this bootstrap in failure messages. Use the exact credential only as the broker Authorization header through the real TS client. It is scoped to this fixture lifetime. The lease endpoint returns a clearly synthetic token and localhost port1 gateway origin; there is no gateway/provider behind it.

For the packaged conversation test, set `ATIKA_FIXTURE_GATEWAY_ORIGIN` to an
explicit `http://127.0.0.1:<port>` synthetic gateway and
`ATIKA_FIXTURE_WORKSPACE_ROOT` to that test's fresh absolute workspace path.
The default closed gateway and `~/isolated-workspace` grant remain in place
for the standalone broker tests.

Every stdin line is one JSON command. Read exactly one stdout ACK per command:

| Command | Response |
|---|---|
| `{op:'stats'}` | `{op:'stats',active:boolean,started:number,completed:number,failed:number,effects:number,waiting:number}` |
| `{op:'hold'}` | `{op:'hold',ok:true}` |
| `{op:'release'}` | `{op:'release',ok:true}` |
| `{op:'revoke'}` | `{op:'revoke',ok:true}` |
| `{op:'stop'}` | `{op:'stop',ok:true}`, then exit0 |

EOF also revokes/stops. Always stop and await the child in harness cleanup. Hold parks only computer-control effects after native preflight/approval. Poll stats until `waiting>0`, cancel/close the turn through the real client, then release and assert effects did not increase. Revoke synchronously invalidates native checkpoints and the broker before releasing held effects. Commands never print the credential.

- Screenshot `{action:'screenshot'}` is allowed and yields actual400x200 JPEG image bytes, `screenId` and display9 metadata, with synthetic display bounds(-800,200,800,400).
- Type `{action:'type',text:'fixture effect'}` requires ask→allow-once and enters the injected effect sink. Fake successful control increments effects; there are no real input events.
- Coordinate actions require the screenshot's screenId. Drag needs start_coordinate and coordinate. Wait is bounded to5s.
- Concurrent calls use one shared official MCP client/ID namespace. The production component owns duplicate/approval/manifest/cancellation checks, not this fixture.

The Python smoke proves guard/private transport/startup/shutdown only. Actual TS client→Swift boundary acceptance is a separate test in the adopted T3 repository; neither fixture nor fake provider proves production identity, native permissions or paid model compatibility.
