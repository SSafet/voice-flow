import Foundation
import CryptoKit

// C18, the device key store: the encodings of 05 §3.2 and the signed texts of
// 05 §3.2, held to real CryptoKit arithmetic. This suite compiles with only
// swift/Device/KeyStore.swift, so it runs before the identity exists.

@main
struct DeviceKeyStoreTests {
    static func main() throws {
        let checks = Checks()
        let key = P256.Signing.PrivateKey()
        let signing = TestSigningKey(key: key)

        // The public key Atika stores is base64 of the standard DER encoding.
        let publicKeyBase64 = DeviceKeyStore.publicKeyBase64(signing)
        let publicKeyDER = Data(base64Encoded: publicKeyBase64)
        checks.check(publicKeyDER != nil, "the public key is base64")
        checks.check(
            (try? P256.Signing.PublicKey(derRepresentation: publicKeyDER ?? Data())) != nil,
            "the public key is standard DER CryptoKit can parse")
        checks.equal(publicKeyDER, key.publicKey.derRepresentation,
                     "the public key is the standard DER encoding")

        // A signature is base64 of the raw 64-byte r||s form CryptoKit emits.
        let message = "nonce-1|device-000000000000000001|2026-09-19T10:00:00.000Z"
        let signatureBase64 = try DeviceKeyStore.signatureBase64(signing, over: message)
        let raw = Data(base64Encoded: signatureBase64)
        checks.equal(raw?.count, 64, "a signature is the raw 64-byte r||s form")
        checks.check(
            P256Check.verify(publicKeyBase64: publicKeyBase64, signatureBase64: signatureBase64, message: message),
            "a signature verifies against the DER public key")
        checks.check(
            !P256Check.verify(publicKeyBase64: publicKeyBase64, signatureBase64: signatureBase64,
                              message: message + "x"),
            "a signature does not verify over another text")

        // The one signed text everywhere, and the sign-in key proof.
        checks.equal(
            DeviceKeyStore.deviceProofText(nonce: "n-1", deviceId: "d-1", sentAt: "t-1"), "n-1|d-1|t-1",
            "the challenge text is nonce|deviceId|sentAt")
        checks.equal(
            DeviceKeyStore.keyProofText(state: "s-1", email: "e@x.test", publicKeyBase64: "pk"),
            "s-1|e@x.test|pk",
            "the sign-in key proof is state|email|publicKey")
        checks.equal(
            DeviceKeyStore.enrollmentProofText(deviceId: "d-1", publicKeyBase64: "pk"), "d-1|pk",
            "the enrollment key proof is deviceId|publicKey")

        // The Keychain item is this-device-only, per 05 §3.2.
        checks.equal(DeviceKeyStore.keychainService, "com.voiceflow.device-identity", "the Keychain service")
        checks.equal(DeviceKeyStore.keychainAccount, "device-p256-private-key", "the Keychain account")
        checks.equal(DeviceKeyStore.keychainAccessibility, "when-unlocked-this-device-only",
                     "the Keychain accessibility")

        // The provider protocol: one key, made once; delete makes a new one next time.
        let provider = MemoryKeyProvider()
        let first = try provider.loadOrCreateKey()
        let second = try provider.loadOrCreateKey()
        checks.equal(first.publicKeyDER, second.publicKeyDER, "loadOrCreateKey returns the same key twice")
        let before = provider.deleteCount
        try provider.deleteKey()
        checks.check(!provider.hasKey, "deleteKey removes the key")
        checks.equal(provider.deleteCount, before + 1, "deleteKey is recorded")
        let third = try provider.loadOrCreateKey()
        checks.check(third.publicKeyDER != first.publicKeyDER, "a deleted key is replaced by a fresh key")

        checks.finish("device key store")
    }
}
