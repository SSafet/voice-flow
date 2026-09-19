import Foundation
import CryptoKit

/// A real P-256 key, held in memory. The suite's key provider, so no test ever
/// touches the owner's Keychain; the signatures it makes are real and the fake
/// gateway verifies them with CryptoKit.
struct TestSigningKey: DeviceSigningKey {
    let key: P256.Signing.PrivateKey
    var publicKeyDER: Data { key.publicKey.derRepresentation }
    func sign(_ message: Data) throws -> Data { try key.signature(for: message).rawRepresentation }
}

final class MemoryKeyProvider: DeviceKeyProvider {
    private var key: TestSigningKey?
    private(set) var deleteCount = 0

    init(key: TestSigningKey = TestSigningKey(key: P256.Signing.PrivateKey())) {
        self.key = key
    }

    var hasKey: Bool { key != nil }

    func loadOrCreateKey() throws -> DeviceSigningKey {
        if let key { return key }
        let created = TestSigningKey(key: P256.Signing.PrivateKey())
        key = created
        return created
    }

    func deleteKey() throws {
        key = nil
        deleteCount += 1
    }
}

/// Verification used by the fake gateway, written the way Atika's verifier is
/// described (05 §3.2): a standard DER public key and a raw 64-byte signature.
enum P256Check {
    static func verify(publicKeyBase64: String, signatureBase64: String, message: String) -> Bool {
        guard let der = Data(base64Encoded: publicKeyBase64),
              let raw = Data(base64Encoded: signatureBase64),
              let publicKey = try? P256.Signing.PublicKey(derRepresentation: der),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: Data(message.utf8))
    }
}
