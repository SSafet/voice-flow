import Foundation
import CryptoKit

/// Prove this is the paired Mac before a rediscovered address receives credentials.
enum SyncIdentity {
    static func proof(nonce: String, token: String) -> String? {
        guard nonce.count == 64, nonce.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        let key = SymmetricKey(data: Data(token.utf8))
        return HMAC<SHA256>.authenticationCode(
            for: Data("voiceflow-sync-probe:\(nonce)".utf8), using: key
        ).map { String(format: "%02x", $0) }.joined()
    }
}
