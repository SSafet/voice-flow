package com.voiceflow.mobile.device

import com.voiceflow.mobile.CloudFailure
import com.voiceflow.mobile.generated.DeviceManifest
import com.voiceflow.mobile.generated.EndpointState
import com.voiceflow.mobile.generated.LocalSwitches
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * Work package P2, component C29 (05 §3.2, 08 §3.3): one device identity on
 * the phone. Sign-in is the existing email-and-code flow with a public key and
 * a proof of possession; tokens come by a signed challenge; no refresh
 * credential exists; the device id the gateway returned never changes; a
 * revoked device reports signed-out with the reason and is not retried.
 *
 * The gateway in these tests verifies real signatures, so the token path is
 * proved, not asserted.
 */
class DeviceIdentityTest {

    private val gateway = FakeDeviceTransport()
    private val keyStore = FakeSigningKeyStore()
    private val keys = DeviceKeys(keyStore)
    private val state = InMemoryDeviceStateStore()
    private val clock = FixedClock(Instant.parse("2026-09-19T10:00:00.000Z").toEpochMilli())

    private fun identity(): DeviceIdentity =
        DeviceIdentity(origin = gateway.origin(), transport = gateway, keys = keys, store = state, now = clock::now)

    private fun signedIn(): DeviceIdentity {
        val identity = identity()
        val challenge = identity.startSignIn("owner@test.local")
        identity.completeSignIn(challenge, "1234 5678", "Pixel 8")
        return identity
    }

    private fun last(path: String) = gateway.calls.last { it.path == path }

    // ── Sign-in (05 §3.2 "Enrolment") ──────────────────────────────────────

    @Test
    fun `sign in sends the public key and a proof over state, email and key, and stores no token`() {
        val identity = identity()
        val challenge = identity.startSignIn("owner@test.local")
        assertEquals("challenge-1", challenge.state)
        assertEquals("owner@test.local", challenge.email)
        assertEquals("2026-09-19T10:05:00.000Z", challenge.expiresAt)

        gateway.signInRefreshToken = "server-refresh-token-that-must-be-ignored"
        val account = identity.completeSignIn(challenge, "1234 5678", "Pixel 8")

        assertEquals(gateway.deviceId, account.deviceId)
        assertEquals(gateway.email, account.email)
        assertEquals(EndpointState.Ready, identity.state())
        assertNull("a signed-in device carries no reason", identity.stateReason())

        val device = last("/api/v1/auth/native/login/complete").body!!.getJSONObject("device")
        assertEquals(keys.publicKeyBase64(), device.getString("publicKey"))
        assertTrue("a proof of possession travels with the key", device.getString("keyProof").isNotBlank())
        assertEquals("android", device.getString("kind"))

        assertEquals("the phone never uses the old refresh path", 0, gateway.refreshCalls)
        assertEquals(account, state.load())
        assertTrue(
            "the stored account shape holds no token of any kind",
            DeviceAccount::class.java.declaredFields.none { it.name.contains("token", ignoreCase = true) },
        )
        val source: AccessTokenSource = identity
        assertEquals("access-from-signin", source.accessToken().accessToken)
    }

    @Test
    fun `the device label is cut to one hundred characters`() {
        val identity = identity()
        val challenge = identity.startSignIn("owner@test.local")
        identity.completeSignIn(challenge, "1234 5678", "L".repeat(200))
        val device = last("/api/v1/auth/native/login/complete").body!!.getJSONObject("device")
        assertEquals(100, device.getString("label").length)
    }

    @Test
    fun `the device id the gateway returned is the one every later call uses`() {
        val identity = signedIn()
        clock.advance(900_000L)
        identity.accessToken()
        assertEquals(gateway.deviceId, last("/api/v1/auth/device/challenge").body!!.getString("deviceId"))
        assertEquals(gateway.deviceId, last("/api/v1/auth/device/token").body!!.getString("deviceId"))

        val restarted = identity()
        restarted.accessToken()
        assertEquals(
            "restarting the app does not mint a new device",
            gateway.deviceId,
            last("/api/v1/auth/device/token").body!!.getString("deviceId"),
        )
    }

    // ── Tokens by signed challenge (05 §3.2 "Access tokens") ───────────────

    @Test
    fun `a token is minted by a signed challenge and the gateway can verify it`() {
        val identity = signedIn()
        clock.advance(900_000L)
        val result = identity.accessToken()
        assertEquals("access-1", result.accessToken)
        assertEquals("2026-09-19T10:30:00.000Z", result.expiresAt)
        assertEquals(1, gateway.tokenCalls)
        assertEquals(
            "the signed bytes are nonce|deviceId|sentAt",
            DeviceKeys.proofText(gateway.challengeNonce, gateway.deviceId, gateway.challengeSentAt),
            keyStore.lastSigned?.toString(Charsets.UTF_8),
        )
    }

    @Test
    fun `a held token is reused until it is inside thirty seconds of expiry`() {
        val identity = signedIn()
        assertEquals("access-from-signin", identity.accessToken().accessToken)
        assertEquals("access-from-signin", identity.accessToken().accessToken)
        assertEquals(0, gateway.tokenCalls)

        clock.advance(900_000L - 30_000L - 1L)
        assertEquals("access-from-signin", identity.accessToken().accessToken)
        assertEquals("still outside the guard, so no challenge", 0, gateway.tokenCalls)

        clock.advance(1L)
        assertEquals("access-1", identity.accessToken().accessToken)
        assertEquals(1, gateway.tokenCalls)
    }

    @Test
    fun `a token is not requested without a signed-in device`() {
        val identity = identity()
        assertThrows(CloudFailure.SignIn::class.java) { identity.accessToken() }
        assertEquals(EndpointState.SignedOut, identity.state())
        assertNull(identity.stateReason())
        assertEquals("no challenge is even asked for", 0, gateway.challengeCalls)
    }

    // ── Revocation and unreachability (05 §3.2 "Endpoint state") ───────────

    @Test
    fun `a revoked device is signed out with the reason and is not retried`() {
        val identity = signedIn()
        identity.accessToken()
        clock.advance(900_000L)
        gateway.revoked = true

        assertThrows(CloudFailure.SignIn::class.java) { identity.accessToken() }
        assertEquals(EndpointState.SignedOut, identity.state())
        assertEquals("revoked", identity.stateReason())

        val attempts = gateway.tokenCalls
        assertThrows(CloudFailure.SignIn::class.java) { identity.accessToken() }
        assertEquals("a revoked device produces one refusal, not a retry loop", attempts, gateway.tokenCalls)
    }

    @Test
    fun `an unreachable gateway is reported and recovers`() {
        val identity = signedIn()
        clock.advance(900_000L)
        gateway.offline = true
        assertThrows(CloudFailure.Network::class.java) { identity.accessToken() }
        assertEquals(EndpointState.Unreachable, identity.state())

        gateway.offline = false
        assertEquals("access-1", identity.accessToken().accessToken)
        assertEquals(EndpointState.Ready, identity.state())
        assertNull(identity.stateReason())
    }

    @Test
    fun `no key and no device row both mean signed out`() {
        val identity = signedIn()
        keys.deleteKey()
        assertEquals(EndpointState.SignedOut, identity.state())
        assertNull(identity.stateReason())
    }

    // ── The manifest (05 §3.2 "The record", 08 §3.3) ───────────────────────

    @Test
    fun `the manifest is published by PUT device manifest with the device's token`() {
        val identity = signedIn()
        val manifest = DeviceManifest(
            appVersion = "0.1.0",
            features = emptyList(),
            switches = LocalSwitches(observe = true),
            allowedClients = emptyList(),
            tools = emptyList(),
            catalogHash = "c5a1e0b7",
        )
        identity.publishManifest(manifest)

        val call = last("/api/v1/device/manifest")
        assertEquals("PUT", call.method)
        assertEquals("access-from-signin", call.accessToken)
        val body = gateway.manifestBodies.last()
        assertEquals("0.1.0", body.getString("appVersion"))
        assertEquals("c5a1e0b7", body.getString("catalogHash"))
        assertTrue(body.getJSONObject("switches").getBoolean("observe"))
        assertEquals(0, body.getJSONArray("features").length())
        assertEquals(0, body.getJSONArray("tools").length())
    }

    // ── Sign-out (05 §3.2 "Sign-out") ──────────────────────────────────────

    @Test
    fun `signing out revokes the row and deletes the private key`() {
        val identity = signedIn()
        identity.signOut()

        assertEquals(1, gateway.deleteCalls)
        assertTrue(
            "the device revokes its own row",
            gateway.calls.any { it.method == "DELETE" && it.path == "/api/v1/me/devices/${gateway.deviceId}" },
        )
        assertFalse("the private key is deleted", keys.hasKey())
        assertNull("the device row is forgotten", state.load())
        assertEquals(EndpointState.SignedOut, identity.state())
        assertEquals(0, gateway.refreshCalls)
    }

    @Test
    fun `signing out works with the network down`() {
        val identity = signedIn()
        gateway.offline = true
        identity.signOut()
        assertFalse(keys.hasKey())
        assertNull(state.load())
        assertEquals(EndpointState.SignedOut, identity.state())
    }
}
