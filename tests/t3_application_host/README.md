# T3 application host checks

`test.sh` exercises real isolated location persistence, symlink/corrupt-metadata refusal, explicit account/home matching and separate namespaces, concurrent native control activity, and the actual coalesced asynchronous shutdown helper. It creates only a temporary test root and an unbound ephemeral loopback socket; no AppKit app, screen/control, Keychain or provider is used.

`typecheck.py --qa` checks every production Swift file including the selected QA entrypoint, using read-only pinned dependency outputs when `VOICE_FLOW_DEPENDENCY_ROOT` is provided. It runs no application. Other relevant checks are `tests/t3_native_tools/test.sh` for the real SDK configuration/revocation boundary, and `tests/t3_native_shell/test.sh` for origin/auth/input contracts, archive packaging and signed **console-only** fake-child lifecycle. The child signal receipt proves SIGUSR2 delivery to the owned process, not real server model cancellation; the adopted T3 server has its own required acceptance.

Example:

```sh
bash tests/t3_application_host/test.sh
VOICE_FLOW_DEPENDENCY_ROOT=/Users/safet/repos/voice-flow-platform \
  python3 tests/t3_application_host/typecheck.py --qa
```

The final application path additionally needs the matching signed T3 archive declaring `nativeAuthorityRevocation: "sigusr2-v1"`, no-account startup proof, real account/home selection, actual WK composition/input/preview safety, and quit/reconnect checks under the root coordinator. The daily app remains disabled and untouched.
