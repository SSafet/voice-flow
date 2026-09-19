import Foundation
import GRDB

/// The one SQLite file this Mac keeps (06 §3.2). It is opened in
/// write-ahead-log mode, which is what a `DatabasePool` gives, so readers never
/// block the writer, and it is brought up to date by the one migrator.
enum ThreadDatabase {
    static let fileName = "threads.sqlite"

    /// Inside the configuration root, so a QA build or a test with
    /// `VOICE_FLOW_CONFIG_ROOT` set never touches the owner's file.
    static func url(configRoot: URL) -> URL {
        configRoot.appendingPathComponent(fileName, isDirectory: false)
    }

    static func open(at url: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try StoreMigrations.migrator().migrate(pool)
        return pool
    }

    private static let lock = NSLock()
    private static var opened: DatabasePool?

    /// The app's one pool, opened the first time it is asked for.
    static func shared() throws -> DatabasePool {
        lock.lock()
        defer { lock.unlock() }
        if let opened { return opened }
        let pool = try open(at: url(configRoot: VoiceFlowPaths.shared.configRoot))
        opened = pool
        return pool
    }

    /// One line for the launch log and the About window. It reports what was
    /// measured, not what is expected: a system SQLite without the full-text
    /// module says so here instead of failing later in the thread store.
    static func describe(_ pool: DatabasePool) throws -> String {
        let version = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "unknown"
        }
        let fts5: String = try pool.write { db in
            do {
                // A temporary table proves the module is there and is gone when
                // the connection closes; nothing is left in the file.
                try db.execute(sql: "CREATE VIRTUAL TABLE temp.fts5_probe USING fts5(text)")
                try db.execute(sql: "DROP TABLE temp.fts5_probe")
                return "FTS5 available"
            } catch {
                return "FTS5 MISSING (\(error))"
            }
        }
        let steps = try pool.read { db in try StoreMigrations.migrator().appliedIdentifiers(db) }
        return "threads.sqlite: GRDB on SQLite \(version), \(fts5), \(steps.count) migration(s) applied"
    }
}
