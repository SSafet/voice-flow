package com.voiceflow.mobile

import org.json.JSONObject
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object SyncIdentity {
    fun verify(host: String, port: String, token: String, timeoutMs: Int = 2_000): Boolean = runCatching {
        val nonce = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        val proof = Net.postJson("http://$host:$port/sync-probe", JSONObject().put("nonce", nonce),
            emptyMap(), timeoutMs, timeoutMs).optString("proof")
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(token.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        val expected = mac.doFinal("voiceflow-sync-probe:$nonce".toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        MessageDigest.isEqual(proof.toByteArray(), expected.toByteArray())
    }.getOrDefault(false)
}
