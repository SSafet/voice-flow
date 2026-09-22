import Foundation
import GRDB

/// The one captured-index file, in the data folder and nowhere else (07 §3.1).
///
/// It is a file of its own on purpose: it is derived, so it must be deletable
/// and rebuildable without touching a single thread record. A
/// `DatabasePool` opens it in write-ahead-log mode, so a tool can read while the
/// indexer writes. There are no migrations: when the schema version moved, the
/// tables are dropped and read again from the sources.
enum CapturedDatabase {
    static let directoryName = "index"
    static let fileName = "captured.sqlite"

    static func url(configRoot: URL) -> URL {
        configRoot
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func open(at url: URL) throws -> DatabasePool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            return try build(at: url)
        } catch {
            // A file that cannot be read or brought to the current schema is not
            // deleted; it is moved aside and a fresh one is built.
            try quarantine(url)
            do {
                return try build(at: url)
            } catch {
                throw CapturedStoreError.databaseUnusable("\(url.path): \(error)")
            }
        }
    }

    private static func build(at url: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: url.path)
        do {
            try reconcileSchema(pool)
            return pool
        } catch {
            try? pool.close()
            throw error
        }
    }

    /// Reads `meta.schema_version`; when it is absent (a new file) or different
    /// from `CapturedSchema.version`, the tables are thrown away and created
    /// again, and the current version is written.
    private static func reconcileSchema(_ pool: DatabasePool) throws {
        let version = try pool.read { db -> Int? in
            guard try tableExists(db, "meta") else { return nil }
            let raw = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'schema_version'")
            return raw.flatMap(Int.init)
        }
        guard version != CapturedSchema.version else { return }
        try pool.write { db in
            try CapturedSchema.dropAll(db)
            try CapturedSchema.apply(to: db)
            try db.execute(
                sql: "INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', ?)",
                arguments: [String(CapturedSchema.version)])
        }
    }

    private static func tableExists(_ db: Database, _ name: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type IN ('table','view') AND name = ?)",
            arguments: [name]) ?? false
    }

    private static func quarantine(_ url: URL) throws {
        let stamp = Int(Date().timeIntervalSince1970)
        let broken = "\(url.path).broken-\(stamp)"
        let files = FileManager.default
        do {
            if files.fileExists(atPath: url.path) {
                try files.moveItem(atPath: url.path, toPath: broken)
            }
            for companion in ["-wal", "-shm"] {
                let path = url.path + companion
                if files.fileExists(atPath: path) {
                    try files.moveItem(atPath: path, toPath: broken + companion)
                }
            }
        } catch {
            throw CapturedStoreError.databaseUnusable("\(url.path): \(error)")
        }
    }
}
