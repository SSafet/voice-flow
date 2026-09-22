import Foundation
import CryptoKit

/// Execution destination stored alongside existing account settings, never a
/// credential or an inferred cloud-sync transport. Old homes remain on disk.
struct CloudNativeHomeSelection: Codable, Equatable, Sendable {
    let origin: String
    let ownerId: String
    let deviceId: String
    let homeId: String
    let label: String
    enum Failure: Error { case changed }
    func matches(_ account: CloudAccountSelection) -> Bool {
        account.signedIn && account.origin == origin && account.userID == ownerId && account.deviceID == deviceId
    }
    var storeKey: String {
        SHA256.hash(data: Data([origin, ownerId, homeId].joined(separator: "\0").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
