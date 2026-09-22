# Native device identity and runtime leases

VoiceFlow sync and the native runtime use one `CloudHTTPClient` actor returned by
`CloudSyncController.credentialOwner()`. The controller reuses the exact actor for
its selected account/device, including across local/cloud sync transport changes.
It retires the prior actor before switching identity. This replaces the native
refresh-only assumption; it does not introduce a second identity store or broker.

The implementation follows Atika's existing auth routes and device identity wire:
`packages/auth/src/routes/index.ts`, `packages/auth/src/device-proof.ts`, and
`gateway/src/device-channel/identity/{token-routes,wire,homes-routes,devices-routes}.ts`.
No gateway, database, or protocol changes are required by this branch.

## Credential lifecycle

- Fresh sign-in saves a pending P-256 private key in the existing Keychain service
  before POSTing completion. Public keys are standard base64 SPKI DER (91 bytes),
  signatures standard base64 P1363 `r || s` (64 bytes), produced by CryptoKit.
  The signed login string is exactly `state|email|publicKey` from the returned
  challenge; the server mints the device ID. No refresh token is expected.
- The existing account-partition Keychain item decodes the old unversioned shape.
  Migration first durably saves version 2 with the pending key, obtains legacy
  bearer access if needed, and enrolls that exact key with `deviceId|publicKey`.
  Enrollment of the same key is idempotent. The enrolled phase is saved before
  device-proof renewal, which revokes the server's old refresh tokens. Only after
  successful proof does the client remove legacy refresh material from the item.
- A saved enrolled key never falls back to the legacy refresh route, including
  after a lost proof response or a failed cleanup write. The next attempt gets
  a fresh server nonce and signs exact `nonce|deviceId|sentAt`; `sentAt` is never
  recomputed or sent as an extra token-body field.
- One renewal task is shared by concurrent sync/runtime calls. If several requests
  reject the same old access token, late 401 responses reuse the already-renewed
  token. Only an explicit expired-challenge refusal retries once with a new nonce.
- Fresh login completion is not idempotent: a lost reply can leave an enrolled
  device whose server-minted ID is unknown locally. The pending key and dispatched
  flag remain durable, and the client refuses another completion dispatch. The
  user must explicitly start a new sign-in or cancel. It never guesses the device
  ID. An ambiguous legacy refresh rotation is likewise never automatically resent.
  Starting sign-in is explicit; restarting the app alone does not clear uncertainty.
- Sign-out retires the actor immediately, writes a keyless retired item before
  best-effort removal/revocation, and retains offline sync data. Revoked/disabled/
  invalid-proof identities are retired too. Late requests cannot restore their
  credentials or erase a newer actor's identity. If Keychain itself refuses the
  retirement write, the error remains visible; the stopped in-memory actor still
  refuses access. A failed item deletion leaves the keyless tombstone.

The existing Keychain namespace and atomic `SecItemUpdate` path remain in use;
private keys use `WhenUnlockedThisDeviceOnly`. Pending login keys are a separate
origin-scoped item in that same service, never a file or second credential system.
There is no renderer, OpenCode configuration, URL, or logging export of secrets.

## Native broker composition boundary

```swift
let owner = try await CloudSyncController.shared.credentialOwner()
let identity = try await owner.identity()
let offer = try await owner.homes()
// Require offer.serving and explicit continuity with the approved environment.
let binding = CloudRuntimeBinding(
    identity: identity, servingHomeID: serving.homeId,
    environmentID: ownedEnvironmentID, environmentGeneration: ownedGeneration)
let lease = try await owner.runtimeCredentials(for: binding)
// Before returning it after other async work:
guard await owner.isCurrent(lease, for: binding) else { /* refuse */ }
```

`identity` contains `origin`, `ownerID`, `deviceID`, and ephemeral UUID `generation`.
Every runtime lease fetches `/api/v1/me/homes/continuable` and requires the current
`serving` home. It never treats a continuable/non-offered home as current authority,
creates a home, or triggers takeover. Observed home changes rotate the identity
generation, invalidating existing leases. A missing serving home requires the
existing explicit home-selection/setup flow. The caller pins its owned child's
ID and generation; the auth actor does not invent an environment association.

The approved private broker wire maps to `{ownerId, deviceId, homeId,
identityGeneration}` using the original `generation.uuidString` spelling.
`gatewayOrigin` is `identity.origin`; token expiry is `lease.expiresAt` formatted
as ISO8601 UTC. Expiry conservatively starts at token-request dispatch time plus
`accessExpiresIn`, not after a delayed response. Environment generation remains
an internal native constraint, outside those four public binding fields.

`CloudSyncController.onIdentityChanged` notifies native composition to stop
serving old leases. Actor retirement and observed home changes trigger it;
callbacks from replaced actors cannot invalidate the newer owner. Notifications
may repeat, so cleanup should be idempotent. This is a hint for prompt cleanup;
`runtimeCredentials` and `isCurrent` remain authoritative checks. Ordinary token
renewal preserves generation. Sign-out, invalid proof, revoked/disabled identity,
account mismatch, or a changed observed home invalidates prior bindings. A new
process/actor has a new generation and needs the normal explicit binding check.

Relevant errors are `signInRequired`, `identityChanged`, `homeSelectionRequired`,
`loginUncertain`, `storage`, `updateRequired`, and `server(status, code)`. Work that
was awaiting a retired actor throws `CancellationError`. Transient/offline HTTP
failure preserves stored keys and queued native data.

## Verification and remaining integration

`bash tests/cloud_device_auth/test.sh` starts an owned ephemeral loopback Node HTTP
server and uses the actual Swift URLSession client. Node verifies the CryptoKit
SPKI and raw signatures, strict request fields, exact signed strings, and cookie/
redirect behavior. The real Codable Keychain vault uses injected in-memory items,
including failed write/delete injection; it never calls the daily Keychain.
The suite covers fresh/migrated identity, committed-response loss and actual TCP
loss, persisted uncertainty, proof recovery, concurrent sync/runtime renewal,
revocation, home binding, and sign-out while renewal is in flight. The normal
`cloud_sync` suite independently covers offline queues and partition preservation.

This branch does not add the native loopback broker, App bootstrap, home choice
UI, or T3 connection lifecycle. Those must use the owner above. Tests do not prove
production login, real Keychain access prompts, GUI behavior, or live inference.
No installed app, daily root, production gateway, or production database is used.
