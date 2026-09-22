#if VOICE_FLOW_QA
import Foundation
import GRDB
import CryptoKit

/// Compiled only into the authenticated isolated QA app. Observation never
/// creates a database, mutates its metadata, or attempts recovery implicitly.
enum ThreadStoreQA {
    static func dump(pool: DatabasePool?, configRoot: URL) throws -> [String: Any] {
        let url = ThreadDatabase.url(configRoot: configRoot)
        var result: [String: Any] = [
            "databasePath": url.path,
            "backups": try ThreadStoreHealth.backups(in: configRoot.appendingPathComponent("backups")).map(file),
            "damagedFiles": try FileManager.default.contentsOfDirectory(at: configRoot, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("threads.sqlite.damaged-") }.sorted { $0.path < $1.path }.map(file),
            "pendingRecovery": FileManager.default.fileExists(atPath: ThreadStoreLaunch.pendingURL(configRoot: configRoot).path)
        ]
        guard let pool else { return result }
        try pool.read { db in
            let id = try String.fetchOne(db, sql: "SELECT value FROM store_meta WHERE key = ?", arguments: [StoreHome.installationIDKey])
            result["installationID"] = id ?? NSNull()
            result["homeID"] = id ?? NSNull()
            result["appliedMigrations"] = try StoreMigrations.migrator().completedMigrations(db)
            var counts: [String: Int] = [:]
            var hashes: [String: String] = [:]
            for (table, column, order) in [
                ("projects", "record", "id"), ("threads", "record", "id"),
                ("turns", "record", "id"), ("items", "record", "id"),
                ("attachments", "record", "id"), ("thread_events", "payload", "thread_id,seq"),
                ("thread_commands", "result", "command_id")
            ] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? 0
                let records = try String.fetchAll(db, sql: "SELECT \(column) FROM \(table) ORDER BY \(order)")
                hashes[table] = hash(try JSONEncoder().encode(records))
            }
            result["counts"] = counts
            result["recordSHA256"] = hashes
            result["projects"] = try String.fetchAll(db, sql: "SELECT record FROM projects ORDER BY id").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
            result["threads"] = try String.fetchAll(db, sql: "SELECT record FROM threads ORDER BY id").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
        }
        return result
    }

    static func seed(_ payload: [String: Any], pool: DatabasePool, paths: VoiceFlowPaths) throws {
        func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
            try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: payload[key] ?? NSNull()))
        }
        let project = try decode(TPProject.self, key: "project")
        let thread = try decode(TPThread.self, key: "thread")
        let items = try decode([TPItem].self, key: "items")
        guard project.path == paths.configRoot.path, thread.projectID == project.id,
              items.allSatisfy({ $0.threadID == thread.id }) else {
            throw ThreadStoreError(code: .notSupported, message: "QA seed references must stay in the isolated root.")
        }
        let store = ThreadStore(pool: pool, paths: paths, homeID: { StoreHome.marker })
        try pool.write { db in
            guard try Int.fetchOne(db, sql: "SELECT count(*) FROM threads") == 0,
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM projects") == 0 else {
                throw ThreadStoreError(code: .notSupported, message: "QA seeding requires an empty canonical store.")
            }
            try store.upsertProject(project, in: db)
            _ = try store.apply([.thread(thread)] + items.map { .itemCompleted($0) }, in: db)
        }
    }

    private static func file(_ url: URL) throws -> [String: Any] {
        let bytes = try Data(contentsOf: url)
        return ["path": url.path, "size": bytes.count, "sha256": hash(bytes)]
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
