package com.voiceflow.mobile.device

import com.voiceflow.mobile.CloudCredentials
import com.voiceflow.mobile.CloudHTTP
import com.voiceflow.mobile.generated.AuthTokenResult
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicReference

/**
 * Work package P2, the deletion the master plan gives it: the refresh-token
 * vault on the phone goes, after the first token by signed challenge
 * (05 §3.2 "Access tokens", 08 §3.3 "No refresh credential exists on this
 * phone"). The cloud sync then takes its access token from the device
 * identity, and nothing on disk can mint one by rotation.
 */
class DeviceCredentialVaultTest {

    private class TokenSource : AccessTokenSource {
        override fun accessToken(): AuthTokenResult = AuthTokenResult(
            accessToken = "token-from-identity",
            expiresAt = "2026-09-19T10:15:00.000Z",
        )
    }

    @Test
    fun `a cloud account carries no token of any kind`() {
        val names = CloudCredentials::class.java.declaredFields.map { it.name.lowercase() }
        assertTrue("a stored cloud account names no token: $names", names.none { it.contains("token") })
    }

    @Test
    fun `the encrypted refresh vault and the refresh route are gone`() {
        val sources = DevicePaths.mainSources()
        assertTrue("no app sources were found", sources.isNotEmpty())
        val text = sources.joinToString("\n") { it.readText() }
        assertFalse("CloudKeystoreVault must be deleted", text.contains("CloudKeystoreVault"))
        assertFalse("the old refresh route must be deleted", text.contains("/auth/native/refresh"))
        assertFalse("no refresh credential may remain in the app", text.contains("refreshToken"))
    }

    @Test
    fun `CloudHTTP takes its access token from the device identity`() {
        val authorization = AtomicReference<String?>(null)
        val http = CloudHTTP(
            "https://atika.test",
            TokenSource(),
            null,
            false,
        ) { _, _, _, token ->
            authorization.set(token)
            JSONObject().put("protocolVersion", 1)
        }
        http.capabilities()
        assertEquals(
            "the sync request carries the token the identity minted",
            "Bearer token-from-identity",
            authorization.get(),
        )
    }
}
