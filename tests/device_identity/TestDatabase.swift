import Foundation
import GRDB

/// A throwaway configuration root and the one threads.sqlite inside it, opened
/// through K8's ThreadDatabase and migrator. Nothing here touches the owner's
/// data.
func openTempDatabase() throws -> (pool: DatabasePool, root: URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vf-device-identity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = ThreadDatabase.url(configRoot: root)
    return (try ThreadDatabase.open(at: url), root)
}

func deviceIdentityRowCount(_ pool: DatabasePool) throws -> Int {
    try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM device_identity") ?? -1 }
}

func storeMetaValue(_ pool: DatabasePool, _ key: String) throws -> String? {
    try pool.read { db in
        try String.fetchOne(db, sql: "SELECT value FROM store_meta WHERE key = ?", arguments: [key])
    }
}

func serverCode(_ error: Error) -> String? {
    guard case let DeviceIdentityError.server(code, _) = error else { return nil }
    return code
}

/// The old refresh-token vault of an install that signed in before the key
/// existed. It records what the identity asked it to do.
final class RecordingLegacyStore: LegacyRefreshTokenStore {
    private(set) var attempts = 0
    private(set) var removals = 0
    var error: Error?

    func removeRefreshMaterial() throws {
        attempts += 1
        if let error { throw error }
        removals += 1
    }
}
