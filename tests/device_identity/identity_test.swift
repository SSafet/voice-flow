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
        let provider = MemoryKeyProvider()
        let (pool, root) = try openTempDatabase()
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = makeIdentity(gateway, provider, pool)
        try await identity.load()

        var state = await identity.state
        checks.equal(state, .signedOut(.none), "a fresh install is signed out")

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
        let enrolledKey = enrollGateway.enrolledPublicKey
        try await enroll.enrollKey(deviceId: "legacy-device-1", accessToken: "legacy-access-1")
        checks.equal(enrollGateway.enrollKeyCalls.count, 2, "a second enrolment is accepted")
        checks.equal(enrollGateway.enrolledPublicKey, enrolledKey, "the enrolled key does not change")

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

        checks.finish("device identity")
    }
}
