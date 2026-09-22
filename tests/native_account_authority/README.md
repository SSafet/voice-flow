# Native account authority composition

`T3NativeAccountAuthority` connects the private broker to the **existing**
`CloudSyncController.credentialOwner()` actor. It creates no HTTP client, vault,
token cache, account/home store, refresh loop, scheduler or identity registry.

App supplies two closures: `credentialOwner` calls the controller's existing method;
`ownedEnvironment` calls the exact signed child's
`T3EnvironmentProcess.authorityEnvironmentIdentity()`. Neither takes a requester-
selected owner, device, account, home or environment ID.

## App seam (root-owned)

1. Require an explicitly selected **native serving home**. Call
   `T3NativeAccountAuthority.connect(destination: .nativeServingHome(id: selectedHomeID),
   credentialOwner: ..., ownedEnvironment: ..., onRevoke: ...)` before child launch.
   `Destination.cloud` means a remote execution environment and is unavailable;
   it is unrelated to enabling the existing cloud **sync transport**.
2. The factory fixes the exact controller-owned actor object, authenticated
   owner/device/generation and its native checkpoint. It does not need an
   environment file yet and grants no permission at connection time.
3. Supply `authority.lease(for:)` as the broker's `leaseProvider` and
   `authority.isCurrent(_:)` as its post-await `isCurrent` closure. The first lease
   reads/pins the real owned child and constructs `CloudRuntimeBinding` with the
   explicit home and native launch UUID. `runtimeCredentials(for:)` verifies the
   current serving home through the existing gateway endpoint; no home is created,
   taken over or guessed. Checks after awaited work verify the same actor, identity,
   child and native lease again. Tokens are returned only as ephemeral broker leases.
4. Native tools obtain `currentSnapshot` synchronously at their checkpoints and
   refuse `nil`. Map its binding/environment into the tool service's binding and
   combine it with real native policy, manifest revision and active turn ownership.
   This account snapshot is **not** a permission policy or a tool execution grant.
   `permits(snapshot)` checks the exact identity and expiry; ordinary renewal does
   not change identity. Async lease validation remains required.
5. Controller identity changes, child exit and explicit home/account replacement
   must call `authority.revoke()` synchronously before scheduling broker/tool cleanup.
   `onRevoke` runs once after the snapshot is closed and may run off MainActor; it
   must use thread-safe native tool revocation and schedule actor/UI cleanup safely.
   `await authority.stop()` clears this adapter's launch state. It **never retires
   sync's credential owner**. A revoked adapter cannot reconnect; construct a new
   one only for a deliberate account/home/launch binding.

The component itself does not install App callbacks or replace existing controller
callbacks. App composition and the combined signed child/broker/tool test remain
integration gates.

## Retirement before queued callbacks

`CloudHTTPClient.nativeAuthorityCheckpoint` is a token-free, lock-protected
`UInt64?` belonging to the exact actor. Ordinary renewal leaves it unchanged.
Observed home-generation changes advance it **before** invalidation notification.
`retire()` changes it permanently to `nil` **before** its callbacks. It cannot wrap
back to a valid value. There is no new observer registry or identity store.

Every synchronous permission read checks that actor checkpoint directly. A changed
stamp immediately closes the old snapshot and invokes the adapter's revoke hook,
even if the controller's MainActor notification has not arrived. A later deliberate
home selection may create a new adapter using the same still-active sync actor's
new stamp; the old adapter cannot reactivate, even if the home changes back.

Snapshots contain only environment, binding, gateway origin and `validatedUntil`.
They expire with the validated native lease. A network validation failure suspends
checkpoints until a fresh lease from the same identity succeeds. Retirement,
identity/home change, changed or lost child permanently revokes the adapter.
Request cancellation does not retire the account or cancel another sync caller's
shared renewal. These are local checkpoints; no code claims to recall a response
already published or detect a remote change before the existing native actor sees it.

## Executed scope

`bash tests/native_account_authority/test.sh` compiles the production component and
actual `CloudHTTPClient`, reusing `tests/cloud_device_auth/server.mjs`. The fixture
performs real local HTTP, CryptoKit signatures and Node verification with encoded
in-memory `CloudKeychainItems`. It covers owner/identity/home/launch binding, cloud
refusal, no automatic home operations, 24 mixed sync/lease calls sharing one renewal,
network failure, cancellation, delayed renewal, immediate retirement while callback
delivery is deferred, home-generation changes and explicit rebinding.

`bash tests/cloud_device_auth/test.sh` verifies the existing auth behavior after the
small native-checkpoint addition. No real Keychain, live login, daily files, GUI,
gateway inference or paid calls are used. The singleton `CloudSyncController` is
not instantiated by these focused tests because its initializer opens the real
shared bridge/Keychain; its production method is the required injected owner seam.
