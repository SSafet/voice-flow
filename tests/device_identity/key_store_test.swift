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

        // The real Keychain provider, against a service name of this run's own,
        // so the owner's item (com.voiceflow.device-identity) is never read,
        // written or deleted. The item is removed again before the suite ends.
        let testService = "com.voiceflow.device-identity.test-\(UUID().uuidString)"
        let provider = KeychainDeviceKeyProvider(service: testService,
                                                 account: DeviceKeyStore.keychainAccount)
        defer { try? provider.deleteKey() }
        do {
            checks.check(!provider.hasKey, "a Keychain service with no item holds no key")
            let created = try provider.loadOrCreateKey()
            checks.check(provider.hasKey, "loadOrCreateKey puts the key in the Keychain")
            let reloaded = try provider.loadOrCreateKey()
            checks.equal(reloaded.publicKeyDER, created.publicKeyDER,
                         "the Keychain returns the one key again and does not make a second")
            let keychainSignature = try DeviceKeyStore.signatureBase64(created, over: message)
            checks.check(
                P256Check.verify(publicKeyBase64: DeviceKeyStore.publicKeyBase64(created),
                                 signatureBase64: keychainSignature, message: message),
                "the key kept in the Keychain signs and its signature verifies")
            try provider.deleteKey()
            checks.check(!provider.hasKey, "deleteKey removes the Keychain item")
            try provider.deleteKey()
            checks.check(true, "deleting an item that is not there is not an error")
            let fresh = try provider.loadOrCreateKey()
            checks.check(fresh.publicKeyDER != created.publicKeyDER,
                         "a deleted key is replaced by a fresh key")
            try provider.deleteKey()
        } catch {
            checks.check(false, "the Keychain provider threw \(error) — run this suite in a logged-in session with the login keychain unlocked")
        }

        // What the Keychain item must be, read from the source: the design
        // chose the file-based Keychain with this-device-only accessibility and
        // decided against the Secure Enclave (05 §3.2, D1). A generic-password
        // item in the data-protection Keychain would need an entitlement
        // VoiceFlow's Developer ID signature cannot carry.
        let source = (try? String(contentsOfFile: "swift/Device/KeyStore.swift", encoding: .utf8)) ?? ""
        checks.check(!source.isEmpty, "swift/Device/KeyStore.swift is read from the repository root")
        checks.check(source.contains("kSecClassGenericPassword"),
                     "the key is a generic-password Keychain item")
        checks.check(source.contains("kSecAttrAccessibleWhenUnlockedThisDeviceOnly"),
                     "the item is reachable only on this device while unlocked")
        checks.check(!source.contains("kSecUseDataProtectionKeychain"),
                     "the data-protection Keychain is not used")
        checks.check(!source.contains("SecureEnclave"),
                     "the Secure Enclave is not used")
        checks.check(source.contains("errSecItemNotFound"),
                     "a missing item is told apart from a Keychain failure")

        checks.finish("device key store")
    }
}
