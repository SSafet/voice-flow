import Foundation
import GRDB

// C19, the device identity, against the fake gateway: sign-in by email code
// with a real P-256 key proof, access tokens by signed challenge and never a
// refresh token, the endpoint states, revocation, sign-out, key enrolment for
// an already-signed-in install, and what survives a restart.

@main
struct DeviceIdentityTests {
    static func makeIdentity(_ gateway: FakeGateway, _ provider: MemoryKeyProvider,
                             _ pool: DatabasePool,
                             legacy: LegacyRefreshTokenStore? = nil) -> DeviceIdentity {
        DeviceIdentity(origin: "https://atika.test", gateway: gateway, keyProvider: provider,
                       database: pool, legacyRefreshTokenStore: legacy)
    }

    static func main() async throws {
        let checks = Checks()

        // ---- Sign-in by email code, with a real key proof --------------------
        let gateway = FakeGateway()
        let provider = MemoryKeyProvider(key: nil)
        let (pool, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity(gateway, provider, pool)
        try await identity.load()

        var state = await identity.state
        checks.equal(state, .signedOut(.none), "a fresh install is signed out")
        checks.check(!provider.hasKey, "load() makes no key of its own")

        let challenge = try await identity.startSignIn(email: "owner@example.test")
        let result = try await identity.completeSignIn(challenge: challenge, code: "123456", label: "Synthetic Mac")
        checks.equal(gateway.completeSignInCalls.count, 1, "the sign-in reaches the gateway once")
        let signIn = gateway.completeSignInCalls[0]
        checks.check(!signIn.publicKeyBase64.isEmpty, "the sign-in carries device.publicKey")
        checks.check(!signIn.keyProofBase64.isEmpty, "the sign-in carries device.keyProof")
        let keyProofText = DeviceKeyStore.keyProofText(
            state: signIn.state, email: signIn.email, publicKeyBase64: signIn.publicKeyBase64)
        checks.check(
            P256Check.verify(publicKeyBase64: signIn.publicKeyBase64,
                             signatureBase64: signIn.keyProofBase64, message: keyProofText),
            "the sign-in key proof verifies over state|email|publicKey")
        let providerKey = try provider.loadOrCreateKey()
        checks.equal(signIn.publicKeyBase64, DeviceKeyStore.publicKeyBase64(providerKey),
                     "the sign-in carries the key provider's public key")
        checks.equal(result.deviceId, gateway.deviceIdValue, "the device id is the server's")
        checks.equal(await identity.deviceId, gateway.deviceIdValue, "the identity remembers its device id")
        state = await identity.state
        checks.equal(state, .ready, "a signed-in device is ready")

        // ---- Access tokens by signed challenge -------------------------------
        let token = try await identity.accessToken()
        checks.equal(token, gateway.accessTokenValue, "the access token is the server's")
        checks.equal(gateway.challengeCalls.count, 1, "the token cost one signed challenge")
        let asked = gateway.challengeCalls[0]
        let signed = gateway.tokenCalls[0]
        checks.equal(asked.deviceId, gateway.deviceIdValue, "the challenge names the device")
        checks.equal(signed.nonce, asked.nonce, "the token uses the challenge's nonce")
        let proofText = DeviceKeyStore.deviceProofText(
            nonce: asked.nonce, deviceId: gateway.deviceIdValue, sentAt: asked.sentAt)
        checks.check(
            P256Check.verify(publicKeyBase64: signIn.publicKeyBase64,
                             signatureBase64: signed.signatureBase64, message: proofText),
            "the challenge signature verifies over nonce|deviceId|sentAt")

        let reused = try await identity.accessToken()
        checks.equal(reused, token, "a live token is returned again")
        checks.equal(gateway.challengeCalls.count, 1, "a live token is not re-minted")
        _ = try await identity.accessToken(force: true)
        checks.equal(gateway.challengeCalls.count, 2, "force mints a new token by proof")
        checks.notEqual(gateway.tokenCalls[1].nonce, gateway.tokenCalls[0].nonce,
                        "each token is signed over the nonce of its own challenge")

        // A token with less than the 30 seconds the rule keeps is not reused.
        gateway.accessExpiresIn = 10
        _ = try await identity.accessToken(force: true)
        let mintedShort = gateway.challengeCalls.count
        _ = try await identity.accessToken()
        checks.equal(gateway.challengeCalls.count, mintedShort + 1,
                     "a token with under 30 seconds left is minted again, not reused")
        gateway.accessExpiresIn = 3600

        // A named server refusal on the token path is not revocation: it is
        // reported and the last good state stays (rule 6).
        gateway.challengeError = .server(code: "rate_limited", message: "too many challenges")
        do {
            _ = try await identity.accessToken(force: true)
            checks.check(false, "a refused challenge must throw")
        } catch {
            checks.equal(serverCode(error), "rate_limited", "a refused challenge keeps the server's code")
        }
        state = await identity.state
        checks.equal(state, .ready, "a named refusal leaves the state alone")
        checks.check(provider.hasKey, "a named refusal keeps the private key")
        gateway.challengeError = nil

        // ---- A refused sign-in is named, and changes nothing -----------------
        let refusedGateway = FakeGateway()
        refusedGateway.completeSignInError = .server(code: "update_required", message: "Update VoiceFlow to sign in")
        let refusedProvider = MemoryKeyProvider()
        let (refusedPool, refusedRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: refusedRoot) }
        let refused = makeIdentity(refusedGateway, refusedProvider, refusedPool)
        try await refused.load()
        let refusedChallenge = try await refused.startSignIn(email: "owner@example.test")
        do {
            _ = try await refused.completeSignIn(challenge: refusedChallenge, code: "123456", label: "Synthetic Mac")
            checks.check(false, "a sign-in refused with update_required must throw")
        } catch {
            checks.equal(serverCode(error), "update_required", "the refusal is update_required")
        }
        state = await refused.state
        checks.equal(state, .signedOut(.none), "a refused sign-in leaves the device signed out")
        checks.equal(await refused.deviceId, nil, "a refused sign-in stores no device id")

        // ---- Revocation: a 401 on the token path -----------------------------
        gateway.revoked = true
        do {
            _ = try await identity.accessToken(force: true)
            checks.check(false, "a revoked device must not mint a token")
        } catch {
            checks.check((error as? DeviceIdentityError) == .notSignedIn,
                         "a revoked device ends notSignedIn")
        }
        state = await identity.state
        checks.equal(state, .signedOut(.revoked), "a revoked device reports signed-out with reason revoked")
        checks.check(!provider.hasKey, "revocation wipes the private key")
        checks.equal(try deviceIdentityRowCount(pool), 0, "revocation drops the device row")
        gateway.revoked = false

        // ---- Unreachable: the key and the row stay ---------------------------
        let offlineGateway = FakeGateway()
        let offlineProvider = MemoryKeyProvider()
        let (offlinePool, offlineRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: offlineRoot) }
        let offline = makeIdentity(offlineGateway, offlineProvider, offlinePool)
        try await offline.load()
        let offlineChallenge = try await offline.startSignIn(email: "owner@example.test")
        _ = try await offline.completeSignIn(challenge: offlineChallenge, code: "123456", label: "Synthetic Mac")
        offlineGateway.unreachable = true
        do {
            _ = try await offline.accessToken(force: true)
            checks.check(false, "an unreachable gateway must throw")
        } catch {
            checks.check((error as? DeviceIdentityError) == .unreachable,
                         "an unreachable gateway throws unreachable")
        }
        state = await offline.state
        checks.equal(state, .unreachable, "an unreachable gateway reports unreachable")
        checks.check(offlineProvider.hasKey, "an unreachable gateway keeps the key")
        checks.equal(try deviceIdentityRowCount(offlinePool), 1, "an unreachable gateway keeps the row")
        offlineGateway.unreachable = false
        _ = try await offline.accessToken(force: true)
        state = await offline.state
        checks.equal(state, .ready, "a reachable gateway returns to ready")

        // ---- Sign-out leaves local data alone --------------------------------
        let outGateway = FakeGateway()
        let outProvider = MemoryKeyProvider()
        let (outPool, outRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: outRoot) }
        try outPool.write { db in
            try db.execute(sql: "INSERT INTO store_meta (key, value) VALUES ('sentinel', 'keep')")
        }
        let signOut = makeIdentity(outGateway, outProvider, outPool)
        try await signOut.load()
        let outChallenge = try await signOut.startSignIn(email: "owner@example.test")
        _ = try await signOut.completeSignIn(challenge: outChallenge, code: "123456", label: "Synthetic Mac")
        _ = try await signOut.accessToken()
        try await signOut.signOut()
        checks.equal(outGateway.revokeCalls.count, 1, "sign-out revokes the device")
        checks.equal(outGateway.revokeCalls[0].deviceId, outGateway.deviceIdValue, "sign-out names the device")
        checks.equal(outGateway.revokeCalls[0].accessToken, outGateway.accessTokenValue,
                     "sign-out revokes with a bearer token")
        checks.check(!outProvider.hasKey, "sign-out deletes the private key")
        checks.equal(try deviceIdentityRowCount(outPool), 0, "sign-out drops the device row")
        state = await signOut.state
        checks.equal(state, .signedOut(.none), "sign-out reports signed out")
        checks.equal(try storeMetaValue(outPool, "sentinel"), "keep", "sign-out leaves local data alone")

        // Signing out when there is nothing to sign out of asks the gateway
        // nothing and still ends signed out.
        let neverGateway = FakeGateway()
        let neverProvider = MemoryKeyProvider(key: nil)
        let (neverPool, neverRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: neverRoot) }
        let never = makeIdentity(neverGateway, neverProvider, neverPool)
        try await never.load()
        try await never.signOut()
        checks.equal(neverGateway.revokeCalls.count, 0, "a sign-out with no device revokes nothing")
        checks.equal(neverGateway.challengeCalls.count, 0, "a sign-out with no device mints no token")
        state = await never.state
        checks.equal(state, .signedOut(.none), "a sign-out with no device still ends signed out")

        // ---- Key enrolment for an already-signed-in install ------------------
        let enrollGateway = FakeGateway()
        let enrollProvider = MemoryKeyProvider()
        let (enrollPool, enrollRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: enrollRoot) }
        let enroll = makeIdentity(enrollGateway, enrollProvider, enrollPool)
        try await enroll.load()
        try await enroll.enrollKey(deviceId: "legacy-device-1", accessToken: "legacy-access-1")
        checks.equal(enrollGateway.enrollKeyCalls.count, 1, "enrolment reaches the gateway once")
        let enrolledCall = enrollGateway.enrollKeyCalls[0]
        checks.equal(enrolledCall.deviceId, "legacy-device-1", "enrolment names the old device")
        checks.equal(enrolledCall.accessToken, "legacy-access-1", "enrolment uses the old access token")
        let enrollProof = DeviceKeyStore.enrollmentProofText(
            deviceId: "legacy-device-1", publicKeyBase64: enrolledCall.publicKeyBase64)
        checks.check(
            P256Check.verify(publicKeyBase64: enrolledCall.publicKeyBase64,
                             signatureBase64: enrolledCall.keyProofBase64, message: enrollProof),
            "the enrolment key proof verifies over deviceId|publicKey")
        try await enroll.enrollKey(deviceId: "legacy-device-1", accessToken: "legacy-access-1")
        checks.equal(enrollGateway.enrollKeyCalls.count, 2, "a second enrolment is accepted")
        checks.equal(enrollGateway.enrollKeyCalls[1].publicKeyBase64, enrolledCall.publicKeyBase64,
                     "the second enrolment offers the one key this device has, not a new one")
        checks.equal(try deviceIdentityRowCount(enrollPool), 0, "enrolment writes no identity row")
        let enrollState = await enroll.state
        checks.equal(enrollState, .signedOut(.none), "enrolment does not sign the device in")

        // ---- A malformed token answer is refused, not half-applied -----------
        let badGateway = FakeGateway()
        let badProvider = MemoryKeyProvider()
        let (badPool, badRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: badRoot) }
        let bad = makeIdentity(badGateway, badProvider, badPool)
        try await bad.load()
        let badChallenge = try await bad.startSignIn(email: "owner@example.test")
        _ = try await bad.completeSignIn(challenge: badChallenge, code: "123456", label: "Synthetic Mac")
        badGateway.invalidTokenResponse = true
        do {
            _ = try await bad.accessToken(force: true)
            checks.check(false, "a token answer with no token must be refused")
        } catch {
            checks.check((error as? DeviceIdentityError) == .invalidResponse,
                         "a token answer with no token is invalidResponse")
        }
        state = await bad.state
        checks.equal(state, .ready, "a malformed answer leaves the last good state alone")

        // ---- Restart: identity survives, the token does not ------------------
        let restartGateway = FakeGateway()
        let restartProvider = MemoryKeyProvider()
        let (restartPool, restartRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: restartRoot) }
        let firstRun = makeIdentity(restartGateway, restartProvider, restartPool)
        try await firstRun.load()
        let restartChallenge = try await firstRun.startSignIn(email: "owner@example.test")
        _ = try await firstRun.completeSignIn(challenge: restartChallenge, code: "123456", label: "Synthetic Mac")
        _ = try await firstRun.accessToken()
        let storedKey = try restartProvider.loadOrCreateKey().publicKeyDER

        let secondRun = makeIdentity(restartGateway, restartProvider, restartPool)
        try await secondRun.load()
        checks.equal(await secondRun.deviceId, restartGateway.deviceIdValue, "the device id survives a restart")
        state = await secondRun.state
        checks.equal(state, .ready, "a restored identity is ready")
        let dumped = try restartPool.read { db in
            try String.fetchAll(db, sql: """
                SELECT quote(origin) || quote(user_id) || quote(email) || quote(device_id) || quote(label)
                    || coalesce(quote(home_id), '')
                FROM device_identity
                """).joined(separator: "|")
        }
        checks.check(!dumped.contains(restartGateway.accessTokenValue), "the access token is never written to the database")
        checks.check(!dumped.contains(storedKey.base64EncodedString()), "the private key is never written to the database")
        let applied = try restartPool.read { db in try StoreMigrations.migrator().appliedIdentifiers(db) }
        checks.check(applied.contains("0001 store meta"), "K8's first step is still registered first")
        checks.check(applied.contains("0002 device identity"),
                     "the identity table arrives with the one step named 0002 device identity")

        // ---- The old refresh material is retired once ------------------------
        let legacyGateway = FakeGateway()
        let legacyProvider = MemoryKeyProvider()
        let (legacyPool, legacyRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: legacyRoot) }
        let legacy = RecordingLegacyStore()
        let legacyIdentity = makeIdentity(legacyGateway, legacyProvider, legacyPool, legacy: legacy)
        try await legacyIdentity.load()
        let legacyChallenge = try await legacyIdentity.startSignIn(email: "owner@example.test")
        _ = try await legacyIdentity.completeSignIn(challenge: legacyChallenge, code: "123456", label: "Synthetic Mac")
        checks.equal(legacy.attempts, 0, "the old refresh material is untouched before a token by proof")
        _ = try await legacyIdentity.accessToken()
        checks.equal(legacy.removals, 1, "the old refresh material is removed after the first token by proof")
        _ = try await legacyIdentity.accessToken(force: true)
        checks.equal(legacy.removals, 1, "the old refresh material is removed once, not on every token")

        // ---- A vault that fails does not break token minting -----------------
        let failingGateway = FakeGateway()
        let failingProvider = MemoryKeyProvider()
        let (failingPool, failingRoot) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        let failing = RecordingLegacyStore()
        failing.error = DeviceIdentityError.storage("keychain busy")
        let failingIdentity = makeIdentity(failingGateway, failingProvider, failingPool, legacy: failing)
        try await failingIdentity.load()
        let failingChallenge = try await failingIdentity.startSignIn(email: "owner@example.test")
        _ = try await failingIdentity.completeSignIn(challenge: failingChallenge, code: "123456", label: "Synthetic Mac")
        let stillToken = try await failingIdentity.accessToken()
        checks.equal(stillToken, failingGateway.accessTokenValue, "a failing vault does not refuse a token")
        checks.equal(failing.removals, 0, "a failing removal is not counted as done")
        failing.error = nil
        _ = try await failingIdentity.accessToken(force: true)
        checks.equal(failing.removals, 1, "the removal is retried on the next token")

        // ---- The routes the gateway half must answer -------------------------
        checks.equal(DeviceIdentityRoutes.signInStart, "/api/v1/auth/native/login/start", "the sign-in start route")
        checks.equal(DeviceIdentityRoutes.signInComplete, "/api/v1/auth/native/login/complete", "the sign-in complete route")
        checks.equal(DeviceIdentityRoutes.enrollKey, "/api/v1/auth/device/key", "the key enrolment route")
        checks.equal(DeviceIdentityRoutes.challenge, "/api/v1/auth/device/challenge", "the challenge route")
        checks.equal(DeviceIdentityRoutes.token, "/api/v1/auth/device/token", "the token route")
        checks.equal(DeviceIdentityRoutes.device("device-9"), "/api/v1/me/devices/device-9", "the one device route")
        checks.equal(DeviceIdentityRoutes.takeoverStart("home-9"), "/api/v1/me/homes/home-9/takeover/start",
                     "the takeover start route")
        checks.equal(DeviceIdentityRoutes.takeoverConfirm("home-9"), "/api/v1/me/homes/home-9/takeover/confirm",
                     "the takeover confirm route")

        // ---- The app's own HTTP client on the wire ---------------------------
        // Held against a stub transport inside one session: the method, the
        // path, the bearer and the body of every call, and the four ways an
        // answer can go wrong. No port is bound and nothing is timed.
        checks.check((try? HTTPDeviceGateway(origin: "https://atika.test", session: StubTransport.session())) != nil,
                     "an https origin is accepted")
        do {
            _ = try HTTPDeviceGateway(origin: "http://atika.test", session: StubTransport.session())
            checks.check(false, "a plain-http origin must be refused")
        } catch {
            checks.check((error as? DeviceIdentityError) == .insecureOrigin,
                         "a plain-http origin is refused with insecureOrigin")
        }

        StubTransport.reset()
        let http = try HTTPDeviceGateway(origin: "https://atika.test", session: StubTransport.session())

        StubTransport.answer(DeviceIdentityRoutes.signInStart,
                             json: #"{"challenge":{"kind":"email_code","state":"state-1","email":"owner@example.test","expiresAt":"2026-09-19T10:05:00.000Z"}}"#)
        if let started = await attempt(checks, "HTTP startSignIn", { try await http.startSignIn(email: "owner@example.test") }) {
            checks.equal(started.state, "state-1", "the sign-in state is read from challenge.state")
            checks.equal(started.email, "owner@example.test", "the sign-in email is read from challenge.email")
            checks.equal(started.expiresAt, "2026-09-19T10:05:00.000Z", "the expiry is read from challenge.expiresAt")
        }
        let startCall = StubTransport.lastCall(DeviceIdentityRoutes.signInStart)
        checks.equal(startCall?.method, "POST", "sign-in start is a POST")
        checks.equal(startCall?.absoluteURL, "https://atika.test/api/v1/auth/native/login/start",
                     "sign-in start is sent to the origin's route")
        checks.equal(startCall?.contentType, "application/json", "sign-in start sends JSON")
        checks.equal(startCall?.accept, "application/json", "sign-in start asks for JSON")
        checks.equal(bodyField(startCall?.bodyText ?? "", "email"), "owner@example.test",
                     "sign-in start carries the email and nothing else the route rejects")

        StubTransport.answer(DeviceIdentityRoutes.signInComplete,
                             json: #"{"deviceId":"device-7","accessToken":"token-7","accessExpiresIn":900,"refreshToken":"must-be-ignored","user":{"id":"user-7","email":"owner@example.test","displayName":"Owner"},"continuableHomes":[{"homeId":"home-7","label":"Safet's MacBook Pro","deviceLastSeenAt":"2026-09-05T09:00:00.000Z","projectCount":3,"threadCount":12}]}"#)
        if let completed = await attempt(checks, "HTTP completeSignIn", {
            try await http.completeSignIn(state: "state-1", email: "owner@example.test", code: "123456",
                                          label: "Synthetic Mac", publicKeyBase64: "cHVibGlj",
                                          keyProofBase64: "cHJvb2Y=")
        }) {
            checks.equal(completed.deviceId, "device-7", "the device id is read from the answer")
            checks.equal(completed.userId, "user-7", "the user id is read from user.id")
            checks.equal(completed.accessToken, "token-7", "the access token is read from the answer")
            checks.equal(completed.accessExpiresIn, 900, "the token's life is read from the answer")
            checks.equal(completed.label, "Synthetic Mac", "the label is the one this device sent")
            checks.equal(completed.continuableHomes.count, 1, "the offered homes are read from the answer")
            checks.equal(completed.continuableHomes.first?.homeId, "home-7", "an offered home carries homeId")
            checks.equal(completed.continuableHomes.first?.deviceLastSeenAt, "2026-09-05T09:00:00.000Z",
                         "an offered home carries deviceLastSeenAt")
            checks.equal(completed.continuableHomes.first?.projectCount, 3, "an offered home carries projectCount")
            checks.equal(completed.continuableHomes.first?.threadCount, 12, "an offered home carries threadCount")
        }
        let completeCall = StubTransport.lastCall(DeviceIdentityRoutes.signInComplete)
        checks.equal(completeCall?.method, "POST", "sign-in complete is a POST")
        checks.equal(bodyField(completeCall?.bodyText ?? "", "state"), "state-1", "sign-in complete carries state")
        checks.equal(bodyField(completeCall?.bodyText ?? "", "code"), "123456", "sign-in complete carries the email code")
        checks.equal(bodyField(completeCall?.bodyText ?? "", "device.kind"), "desktop", "the device kind is desktop")
        checks.equal(bodyField(completeCall?.bodyText ?? "", "device.label"), "Synthetic Mac", "the device carries its label")
        checks.equal(bodyField(completeCall?.bodyText ?? "", "device.publicKey"), "cHVibGlj", "the device carries device.publicKey")
        checks.equal(bodyField(completeCall?.bodyText ?? "", "device.keyProof"), "cHJvb2Y=", "the device carries device.keyProof")
        checks.check(!(completeCall?.bodyText ?? "").contains("refreshToken"),
                     "no refresh token is ever sent")

        StubTransport.answer(DeviceIdentityRoutes.enrollKey, json: "{}")
        _ = await attempt(checks, "HTTP enrollKey", {
            try await http.enrollKey(deviceId: "device-7", publicKeyBase64: "cHVibGlj",
                                     keyProofBase64: "cHJvb2Y=", accessToken: "token-7")
        })
        let enrollCall = StubTransport.lastCall(DeviceIdentityRoutes.enrollKey)
        checks.equal(enrollCall?.method, "POST", "key enrolment is a POST")
        checks.equal(enrollCall?.authorization, "Bearer token-7", "key enrolment carries the bearer token")
        checks.equal(bodyField(enrollCall?.bodyText ?? "", "publicKey"), "cHVibGlj", "key enrolment sends publicKey")
        checks.equal(bodyField(enrollCall?.bodyText ?? "", "keyProof"), "cHJvb2Y=", "key enrolment sends keyProof")

        StubTransport.answer(DeviceIdentityRoutes.challenge,
                             json: #"{"nonce":"nonce-7","sentAt":"2026-09-19T10:00:00.000Z","expiresInSec":60}"#)
        if let asked = await attempt(checks, "HTTP challenge", { try await http.challenge(deviceId: "device-7") }) {
            checks.equal(asked.nonce, "nonce-7", "the nonce is read from the answer")
            checks.equal(asked.sentAt, "2026-09-19T10:00:00.000Z", "sentAt is read from the answer")
            checks.equal(asked.expiresInSec, 60, "the nonce's life is read from the answer")
        }
        let challengeCall = StubTransport.lastCall(DeviceIdentityRoutes.challenge)
        checks.equal(challengeCall?.method, "POST", "the challenge is a POST")
        checks.equal(bodyField(challengeCall?.bodyText ?? "", "deviceId"), "device-7", "the challenge names the device")
        checks.check(challengeCall != nil && challengeCall?.authorization == nil,
                     "the challenge is proved by the key and needs no bearer token")

        StubTransport.answer(DeviceIdentityRoutes.token,
                             json: #"{"accessToken":"token-8","accessExpiresIn":900,"user":{"id":"user-7","email":"owner@example.test"}}"#)
        if let minted = await attempt(checks, "HTTP token", {
            try await http.token(deviceId: "device-7", nonce: "nonce-7", signatureBase64: "c2ln")
        }) {
            checks.equal(minted.accessToken, "token-8", "the minted token is read from the answer")
            checks.equal(minted.userId, "user-7", "the token answer carries the user id")
        }
        let tokenCall = StubTransport.lastCall(DeviceIdentityRoutes.token)
        checks.equal(bodyField(tokenCall?.bodyText ?? "", "deviceId"), "device-7", "the token request names the device")
        checks.equal(bodyField(tokenCall?.bodyText ?? "", "nonce"), "nonce-7", "the token request carries the nonce")
        checks.equal(bodyField(tokenCall?.bodyText ?? "", "signature"), "c2ln", "the token request carries the signature")

        StubTransport.answer(DeviceIdentityRoutes.device("device-7"), json: "{}")
        _ = await attempt(checks, "HTTP revokeDevice", {
            try await http.revokeDevice(deviceId: "device-7", accessToken: "token-8")
        })
        let revokeCall = StubTransport.lastCall(DeviceIdentityRoutes.device("device-7"))
        checks.equal(revokeCall?.method, "DELETE", "sign-out deletes the device row")
        checks.equal(revokeCall?.authorization, "Bearer token-8", "the delete carries the bearer token")

        StubTransport.answer(DeviceIdentityRoutes.takeoverStart("home-7"), json: "{}")
        _ = await attempt(checks, "HTTP startTakeover", {
            try await http.startTakeover(homeId: "home-7", accessToken: "token-8")
        })
        let takeoverStartCall = StubTransport.lastCall(DeviceIdentityRoutes.takeoverStart("home-7"))
        checks.equal(takeoverStartCall?.method, "POST", "asking for the takeover code is a POST")
        checks.equal(takeoverStartCall?.authorization, "Bearer token-8", "asking for the code carries the bearer token")

        StubTransport.answer(DeviceIdentityRoutes.takeoverConfirm("home-7"), json: #"{"homeId":"home-7"}"#)
        if let confirmed = await attempt(checks, "HTTP confirmTakeover", {
            try await http.confirmTakeover(homeId: "home-7", code: "654321", accessToken: "token-8")
        }) {
            checks.equal(confirmed.homeId, "home-7", "the confirmation yields the home id")
        }
        let confirmCall = StubTransport.lastCall(DeviceIdentityRoutes.takeoverConfirm("home-7"))
        checks.equal(bodyField(confirmCall?.bodyText ?? "", "code"), "654321", "the confirmation carries the code")
        checks.equal(confirmCall?.authorization, "Bearer token-8", "the confirmation carries the bearer token")

        // The four ways an answer can go wrong.
        StubTransport.answer(DeviceIdentityRoutes.challenge, status: 401,
                             json: #"{"error":{"code":"device_revoked","message":"this device was removed"}}"#)
        do {
            _ = try await http.challenge(deviceId: "device-7")
            checks.check(false, "a 401 must throw")
        } catch {
            checks.check((error as? DeviceIdentityError) == .unauthorized, "a 401 is unauthorized")
        }
        StubTransport.answer(DeviceIdentityRoutes.challenge, status: 400,
                             json: #"{"error":{"code":"update_required","message":"Update VoiceFlow to sign in"}}"#)
        do {
            _ = try await http.challenge(deviceId: "device-7")
            checks.check(false, "a named refusal must throw")
        } catch {
            checks.equal(serverCode(error), "update_required", "a refusal keeps the server's code")
            checks.equal(serverMessage(error), "Update VoiceFlow to sign in", "a refusal keeps the server's sentence")
        }
        StubTransport.answer(DeviceIdentityRoutes.challenge, json: "not json at all")
        do {
            _ = try await http.challenge(deviceId: "device-7")
            checks.check(false, "an answer that does not decode must throw")
        } catch {
            checks.check((error as? DeviceIdentityError) == .invalidResponse,
                         "an answer that does not decode is invalidResponse")
        }
        StubTransport.failTransport(DeviceIdentityRoutes.challenge)
        do {
            _ = try await http.challenge(deviceId: "device-7")
            checks.check(false, "a transport failure must throw")
        } catch {
            checks.check((error as? DeviceIdentityError) == .unreachable,
                         "a transport failure is unreachable")
        }

        checks.finish("device identity")
    }
}
