package com.voiceflow.mobile.device

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyFactory
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

/**
 * Work package P2, component C28 (05 §3.2 "The key" and "The proof"; 08 §3.3):
 * a P-256 key generated inside the Android Keystore, not extractable, whose
 * public key travels as base64 of the standard DER encoding and whose
 * signatures travel as base64 of the raw 64-byte `r||s` form over the one
 * signed text `nonce|deviceId|sentAt`.
 *
 * Every signature produced here is checked with the platform's own verifier
 * and an independent DER encoder, never with the production conversion.
 */
class DeviceKeysTest {

    private val store = FakeSigningKeyStore()
    private val keys = DeviceKeys(store)

    private val device = "01AAAAAAAAAAAAAAAAAAAAAAAA"
    private val nonce = "nonce-1"
    private val sentAt = "2026-09-19T10:00:00.000Z"

    private fun verify(message: ByteArray, signatureBase64: String): Boolean {
        val raw = Base64.getDecoder().decode(signatureBase64)
        assertEquals("the signature is the raw 64-byte r||s form", 64, raw.size)
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initVerify(store.publicKey())
        signature.update(message)
        return signature.verify(EcdsaBytes.rawToDer(raw))
    }

    // ── The one signed text (05 §3.2) ──────────────────────────────────────

    @Test
    fun `the proof text is nonce pipe deviceId pipe sentAt`() {
        assertEquals("nonce-1|$device|$sentAt", DeviceKeys.proofText(nonce, device, sentAt))
    }

    @Test
    fun `the enrolment proof text is state pipe email pipe publicKey`() {
        assertEquals(
            "challenge|owner@test.local|PUBLICKEY",
            DeviceKeys.enrolmentProofText("challenge", "owner@test.local", "PUBLICKEY"),
        )
    }

    // ── The key (05 §3.2 "The key") ────────────────────────────────────────

    @Test
    fun `the public key is base64 of the P-256 DER encoding`() {
        keys.ensureKey()
        assertEquals(
            "the public key travels as base64 of the store's DER encoding",
            Base64.getEncoder().encodeToString(store.publicKeyDer()),
            keys.publicKeyBase64(),
        )
        val parsed = KeyFactory.getInstance("EC")
            .generatePublic(X509EncodedKeySpec(store.publicKeyDer())) as ECPublicKey
        assertEquals("the curve is P-256", 256, parsed.params.curve.field.fieldSize)
    }

    @Test
    fun `the key is generated once and reused`() {
        keys.ensureKey()
        keys.ensureKey()
        assertEquals("generating twice would change the device's identity", 1, store.generateCalls)
        val first = keys.publicKeyBase64()
        keys.ensureKey()
        assertEquals(first, keys.publicKeyBase64())
        assertEquals(1, store.generateCalls)
    }

    @Test
    fun `deleting the key makes the device keyless and a new key is a new key`() {
        keys.ensureKey()
        val first = keys.publicKeyBase64()
        keys.deleteKey()
        assertFalse("sign-out deletes the private key (05 §3.2)", keys.hasKey())
        keys.ensureKey()
        assertEquals(2, store.generateCalls)
        assertNotEquals(first, keys.publicKeyBase64())
        assertTrue(keys.hasKey())
    }

    // ── The proof (05 §3.2 "The proof") ────────────────────────────────────

    @Test
    fun `a proof signs exactly the proof text and verifies with the public key`() {
        keys.ensureKey()
        val signature = keys.signProof(nonce, device, sentAt)
        assertEquals(
            "the signed bytes are the proof text itself",
            "nonce-1|$device|$sentAt",
            store.lastSigned?.toString(Charsets.UTF_8),
        )
        assertTrue(verify("nonce-1|$device|$sentAt".toByteArray(), signature))
    }

    @Test
    fun `a proof for one device does not verify for another`() {
        keys.ensureKey()
        val signature = keys.signProof(nonce, device, sentAt)
        assertFalse(
            "the device id is inside the signed text",
            verify("nonce-1|01BBBBBBBBBBBBBBBBBBBBBBBB|$sentAt".toByteArray(), signature),
        )
    }

    @Test
    fun `an enrolment proof verifies over state, email and the public key`() {
        keys.ensureKey()
        val signature = keys.signEnrolmentProof("challenge", "owner@test.local")
        val text = "challenge|owner@test.local|${keys.publicKeyBase64()}"
        assertEquals(text, store.lastSigned?.toString(Charsets.UTF_8))
        assertTrue(verify(text.toByteArray(), signature))
    }

    // ── The two encodings (05 §3.2: raw r||s, converted from DER) ──────────

    @Test
    fun `a short DER integer is left-padded into the 64-byte raw form`() {
        val der = byteArrayOf(0x30, 0x08, 0x02, 0x01, 0x01, 0x02, 0x03, 0x00, 0x80.toByte(), 0x7F)
        val raw = DeviceKeys.derToP1363(der)
        assertEquals("the raw form is always 64 bytes", 64, raw.size)
        assertEquals(1, raw[31].toInt())
        assertEquals(0x80, raw[62].toInt() and 0xFF)
        assertEquals(0x7F, raw[63].toInt() and 0xFF)
        assertTrue("r's other bytes are zero", raw.copyOfRange(0, 31).all { it == 0.toByte() })
        assertTrue("s's leading bytes are zero", raw.copyOfRange(32, 62).all { it == 0.toByte() })
    }

    @Test
    fun `the raw form converts back to minimal DER, and the pair round-trips`() {
        val raw = ByteArray(64).also { it[31] = 1; it[63] = 2 }
        val der = DeviceKeys.p1363ToDer(raw)
        assertArrayEquals(
            "a small integer is minimal DER, not padded",
            byteArrayOf(0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x02),
            der,
        )
        assertArrayEquals(raw, DeviceKeys.derToP1363(der))
        assertArrayEquals(raw, EcdsaBytes.derToRaw(der))
    }

    @Test
    fun `a DER signature the platform produced converts to the raw form and back`() {
        keys.ensureKey()
        val der = store.signDer("round-trip".toByteArray())
        val raw = DeviceKeys.derToP1363(der)
        assertEquals(64, raw.size)
        assertArrayEquals(der, DeviceKeys.p1363ToDer(raw))
        assertArrayEquals(raw, EcdsaBytes.derToRaw(der))
    }
}
