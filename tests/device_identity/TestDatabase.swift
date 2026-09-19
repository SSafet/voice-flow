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

func serverMessage(_ error: Error) -> String? {
    guard case let DeviceIdentityError.server(_, message) = error else { return nil }
    return message
}

/// Runs a call that must succeed. A throw is one named failed check instead of
/// an abandoned suite, so one broken call cannot hide every check after it.
func attempt<T>(_ checks: Checks, _ what: String, _ body: () async throws -> T) async -> T? {
    do {
        return try await body()
    } catch {
        checks.check(false, "\(what): threw \(error)")
        return nil
    }
}

/// A field of a recorded JSON request body, addressed as `device.publicKey`.
func bodyField(_ bodyText: String, _ path: String) -> String? {
    guard let data = bodyText.data(using: .utf8),
          var node = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let parts = path.split(separator: ".").map(String.init)
    for part in parts.dropLast() {
        guard let next = node[part] as? [String: Any] else { return nil }
        node = next
    }
    guard let last = parts.last, let value = node[last] else { return nil }
    if let text = value as? String { return text }
    if let number = value as? NSNumber { return number.stringValue }
    return String(describing: value)
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
