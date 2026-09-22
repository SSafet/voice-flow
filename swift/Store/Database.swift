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
        // A second store handle waits for the canonical writer transaction,
        // then reads its settlement instead of racing or failing immediately.
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        do {
            try pool.read { try ThreadStoreSchemaProof.validate($0) }
            try StoreMigrations.migrator().migrate(pool)
            try pool.read { try ThreadStoreSchemaProof.validate($0) }
            return pool
        } catch { try? pool.close(); throw error }
    }

    private static let lock = NSLock()
    private static var opened: DatabasePool?

    /// Canonical reads and sends cannot implicitly open an unverified store.
    /// Only the launch/recovery path may install the app's pool.
    static func shared() throws -> DatabasePool {
        lock.lock()
        defer { lock.unlock() }
        if let opened { return opened }
        throw ThreadStoreError(code: .notSupported, message: "Thread history is unavailable until store recovery completes.")
    }

    static func install(_ pool: DatabasePool, configRoot: URL) throws {
        guard URL(fileURLWithPath: pool.path).standardizedFileURL == url(configRoot: configRoot).standardizedFileURL else {
            throw ThreadStoreError(code: .notSupported, message: "The verified store is outside this app's configuration root.")
        }
        try pool.read { db in
            try ThreadStoreSchemaProof.validate(db)
            guard try StoreMigrations.migrator().hasCompletedMigrations(db) else {
                throw ThreadStoreError(code: .notSupported, message: "The thread store still requires migration.")
            }
        }
        lock.lock()
        defer { lock.unlock() }
        guard opened == nil || opened === pool else {
            throw ThreadStoreError(code: .notSupported, message: "The thread store is already open.")
        }
        opened = pool
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
