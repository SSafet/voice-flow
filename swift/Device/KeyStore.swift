import Foundation
import CryptoKit
import Security

protocol DeviceSigningKey {
    var publicKeyDER: Data { get }
    func sign(_ message: Data) throws -> Data
}

protocol DeviceKeyProvider {
    func loadOrCreateKey() throws -> DeviceSigningKey
    func deleteKey() throws
    var hasKey: Bool { get }
}

enum DeviceKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
    case malformedKey
}

enum DeviceKeyStore {
    static let keychainService = "com.voiceflow.device-identity"
    static let keychainAccount = "device-p256-private-key"
    static let keychainAccessibility = "when-unlocked-this-device-only"

    static func publicKeyBase64(_ key: DeviceSigningKey) -> String {
        key.publicKeyDER.base64EncodedString()
    }

    static func signatureBase64(_ key: DeviceSigningKey, over text: String) throws -> String {
        try key.sign(Data(text.utf8)).base64EncodedString()
    }

    static func deviceProofText(nonce: String, deviceId: String, sentAt: String) -> String {
        "\(nonce)|\(deviceId)|\(sentAt)"
    }

    static func keyProofText(state: String, email: String, publicKeyBase64: String) -> String {
        "\(state)|\(email)|\(publicKeyBase64)"
    }

    static func enrollmentProofText(deviceId: String, publicKeyBase64: String) -> String {
        "\(deviceId)|\(publicKeyBase64)"
    }
}

private struct P256SigningKey: DeviceSigningKey {
    let key: P256.Signing.PrivateKey

    var publicKeyDER: Data { key.publicKey.derRepresentation }

    func sign(_ message: Data) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }
}

final class KeychainDeviceKeyProvider: DeviceKeyProvider {
    private let service: String
    private let account: String

    init(service: String = DeviceKeyStore.keychainService,
         account: String = DeviceKeyStore.keychainAccount) {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    var hasKey: Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func loadOrCreateKey() throws -> DeviceSigningKey {
        if let stored = try readKey() {
            return stored
        }
        let created = P256.Signing.PrivateKey()
        var query = baseQuery
        query[kSecValueData as String] = created.rawRepresentation
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return P256SigningKey(key: created)
        case errSecDuplicateItem:
            guard let stored = try readKey() else {
                throw DeviceKeyStoreError.keychain(status)
            }
            return stored
        default:
            throw DeviceKeyStoreError.keychain(status)
        }
    }

    func deleteKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceKeyStoreError.keychain(status)
        }
    }

    private func readKey() throws -> DeviceSigningKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
                throw DeviceKeyStoreError.malformedKey
            }
            return P256SigningKey(key: key)
        case errSecItemNotFound:
            return nil
        default:
            throw DeviceKeyStoreError.keychain(status)
        }
    }
}
