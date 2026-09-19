package com.voiceflow.mobile.device

import com.voiceflow.mobile.CloudFailure
import org.json.JSONObject
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger

/**
 * The fake gateway of work package P2 (05 §3.2). It speaks the identity routes
 * over the same `DeviceTransport` seam the phone uses, and it verifies real
 * P-256 signatures with the platform's own `SHA256withECDSA`: a proof the
 * phone signed wrongly is refused, so a test cannot pass by agreeing with
 * itself. It also counts calls and records request bodies, which is how the
 * "no refresh token", "the device id does not change" and "one refusal, no
 * retry" rules are observed.
 */
internal class FakeDeviceTransport(private val expectedOrigin: String = "https://atika.test") : DeviceTransport {

    data class Call(val method: String, val path: String, val body: JSONObject?, val accessToken: String?)

    val calls = mutableListOf<Call>()
    val manifestBodies = mutableListOf<JSONObject>()

    @Volatile var offline = false
    @Volatile var revoked = false

    private val challengeCount = AtomicInteger()
    private val tokenCount = AtomicInteger()
    private val refreshCount = AtomicInteger()
    private val deleteCount = AtomicInteger()

    val challengeCalls: Int get() = challengeCount.get()
    val tokenCalls: Int get() = tokenCount.get()
    val refreshCalls: Int get() = refreshCount.get()
    val deleteCalls: Int get() = deleteCount.get()

    var deviceId = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    var userId = "01BBBBBBBBBBBBBBBBBBBBBBBB"
    var email = "owner@test.local"
    var displayName = "Owner"
    var accessExpiresIn = 900
    var signInAccessToken = "access-from-signin"

    /** When set, the sign-in response wrongly carries a refresh token; the phone must ignore it. */
    var signInRefreshToken: String? = null

    var challengeNonce = "nonce-abc"
    var challengeSentAt = "2026-09-19T10:00:00.000Z"

    var registeredPublicKeyDer: ByteArray? = null
        private set

    fun origin(): String = expectedOrigin

    override fun send(method: String, path: String, body: JSONObject?, accessToken: String?): JSONObject {
        calls += Call(method, path, body?.let { JSONObject(it.toString()) }, accessToken)
        if (offline) throw CloudFailure.Network()

        when {
            method == "POST" && path == "/api/v1/auth/native/login/start" -> {
                val mail = body?.getString("email") ?: throw CloudFailure.InvalidResponse()
                return JSONObject().put(
                    "challenge",
                    JSONObject()
                        .put("state", "challenge-1")
                        .put("email", mail)
                        .put("expiresAt", "2026-09-19T10:05:00.000Z"),
                )
            }

            method == "POST" && path == "/api/v1/auth/native/login/complete" -> {
                val device = body?.optJSONObject("device") ?: throw CloudFailure.InvalidResponse()
                val publicKey = device.optString("publicKey")
                val keyProof = device.optString("keyProof")
                if (publicKey.isBlank() || keyProof.isBlank()) throw CloudFailure.Server(400, "no_key")
                val der = Base64.getDecoder().decode(publicKey)
                val text = (body.optString("state") + "|" + body.optString("email") + "|" + publicKey)
                if (!verifies(der, text, keyProof)) throw CloudFailure.Server(401, "invalid_key_proof")
                registeredPublicKeyDer = der
                val response = JSONObject()
                    .put("deviceId", deviceId)
                    .put("accessToken", signInAccessToken)
                    .put("accessExpiresIn", accessExpiresIn)
                    .put(
                        "user",
                        JSONObject().put("id", userId).put("email", email).put("displayName", displayName),
                    )
                signInRefreshToken?.let { response.put("refreshToken", it) }
                return response
            }

            path == "/api/v1/auth/native/refresh" -> {
                refreshCount.incrementAndGet()
                throw AssertionError("the phone must never use the old refresh path")
            }

            method == "POST" && path == "/api/v1/auth/device/challenge" -> {
                challengeCount.incrementAndGet()
                if (revoked) throw CloudFailure.SignIn()
                val named = body?.optString("deviceId") ?: ""
                if (named != deviceId) throw CloudFailure.Server(404, "device_not_found")
                return JSONObject()
                    .put("nonce", challengeNonce)
                    .put("sentAt", challengeSentAt)
                    .put("expiresInSec", 60)
            }

            method == "POST" && path == "/api/v1/auth/device/token" -> {
                tokenCount.incrementAndGet()
                if (revoked) throw CloudFailure.SignIn()
                val der = registeredPublicKeyDer ?: throw AssertionError("no key has been enrolled")
                val text = body?.optString("nonce") + "|" + body?.optString("deviceId") + "|" + challengeSentAt
                val signature = body?.optString("signature") ?: ""
                if (!verifies(der, text, signature)) throw CloudFailure.SignIn()
                val number = tokenCount.get()
                return JSONObject()
                    .put("accessToken", "access-$number")
                    .put("accessExpiresIn", accessExpiresIn)
                    .put(
                        "user",
                        JSONObject().put("id", userId).put("email", email).put("displayName", displayName),
                    )
            }

            method == "PUT" && path == "/api/v1/device/manifest" -> {
                manifestBodies += JSONObject(body.toString())
                return JSONObject().put("ok", true)
            }

            method == "DELETE" && path.startsWith("/api/v1/me/devices/") -> {
                deleteCount.incrementAndGet()
                return JSONObject().put("ok", true)
            }
        }
        throw AssertionError("the phone called an unexpected route: $method $path")
    }

    /** An independent check: raw `r||s` base64 decoded, re-encoded to DER, verified. */
    private fun verifies(publicKeyDer: ByteArray, text: String, signatureBase64: String): Boolean = runCatching {
        val raw = Base64.getDecoder().decode(signatureBase64)
        if (raw.size != 64) {
            false
        } else {
            val verifier = Signature.getInstance("SHA256withECDSA")
            verifier.initVerify(KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(publicKeyDer)))
            verifier.update(text.toByteArray(Charsets.UTF_8))
            verifier.verify(EcdsaBytes.rawToDer(raw))
        }
    }.getOrDefault(false)
}
