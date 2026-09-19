package com.voiceflow.mobile.device

import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * A JVM stand-in for the Android Keystore: one P-256 key pair, generated in
 * this process, signing with the platform's own `SHA256withECDSA`, which emits
 * DER just as the Android Keystore does. The private key never leaves the
 * object, exactly as the real key never leaves secure hardware; the only
 * handles the production code has are the public key and a signature.
 */
internal class FakeSigningKeyStore : SigningKeyStore {

    private var pair: KeyPair? = null
    private val random = SecureRandom()

    var generateCalls = 0
        private set
    var signCalls = 0
        private set
    var lastSigned: ByteArray? = null
        private set

    override fun hasKey(): Boolean = pair != null

    override fun generateP256Key() {
        val generator = KeyPairGenerator.getInstance("EC")
        generator.initialize(ECGenParameterSpec("secp256r1"), random)
        pair = generator.generateKeyPair()
        generateCalls++
    }

    override fun publicKeyDer(): ByteArray =
        pair?.public?.encoded ?: throw IllegalStateException("no key has been generated")

    override fun signDer(message: ByteArray): ByteArray {
        val key = pair ?: throw IllegalStateException("no key has been generated")
        val signature = Signature.getInstance("SHA256withECDSA")
        signature.initSign(key.private, random)
        signature.update(message)
        lastSigned = message.copyOf()
        signCalls++
        return signature.sign()
    }

    override fun deleteKey() {
        pair = null
    }

    fun publicKey(): PublicKey = pair?.public ?: throw IllegalStateException("no key has been generated")
}
