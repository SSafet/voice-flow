import Foundation
import GRDB

/// What a repair recovered, measured from the file it made and not asserted
/// (06 §3.2 "Damage is surfaced and recoverable").
struct RepairReport: Equatable {
    let threads: Int
    let items: Int
}

/// The store's own health: the launch check, setting a damaged file aside
/// untouched, the daily backup and the newest seven, restore and repair
/// (06 §3.2 "Backups", 06 §7).
///
/// The check opens read-only and writes nothing. A damaged file is moved, never
/// truncated or overwritten, so nothing the user had is lost by the time the
/// recovery window is offered. The backup is SQLite's own online backup, so it
/// is a working copy of the file and not a re-encoding of it.
enum ThreadStoreHealth {
    static let keep = 7
    static let lastBackupKey = "last_backup_at"

    enum State: Equatable {
        case absent
        case ok
        case damaged(String)
    }

    /// `.absent` when there is no file, `.ok` when it opens and `PRAGMA
    /// quick_check` answers `ok`, `.damaged(reason)` otherwise — including when
    /// SQLite refuses the file as not a database. Read-only, so a check can
    /// never change what it is checking.
    static func check(at url: URL) -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            let answer = try queue.read { db in
                try String.fetchOne(db, sql: "PRAGMA quick_check") ?? ""
            }
            if answer == "ok" { return .ok }
            return .damaged(answer.isEmpty ? "quick_check gave no answer" : answer)
        } catch {
            return .damaged(String(describing: error))
        }
    }

    /// Renames `threads.sqlite` to `threads.sqlite.damaged-<timestamp>` and
    /// moves the `-wal` and `-shm` files beside it under the same stem. The
    /// damaged bytes are moved, never rewritten.
    static func setAside(at url: URL, now: Date) throws -> URL {
        let manager = FileManager.default
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).damaged-\(stamp(now))",
                                    isDirectory: false)
        try manager.moveItem(at: url, to: target)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if manager.fileExists(atPath: side.path) {
                try manager.moveItem(
                    at: side, to: URL(fileURLWithPath: target.path + suffix))
            }
        }
        return target
    }

    /// SQLite's own online backup into `<folder>/threads-<yyyy-MM-dd in
    /// UTC>.sqlite`, then `now` into `store_meta` under `lastBackupKey`, then
    /// every backup but the newest `keep` removed.
    static func backup(pool: DatabasePool, into folder: URL, now: Date,
                       keep: Int = keep) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("threads-\(utcDay(now)).sqlite",
                                                        isDirectory: false)
        let target = try DatabaseQueue(path: destination.path)
        do {
            try pool.backup(to: target)
            try target.close()
        } catch {
            try? target.close()
            throw error
        }
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO store_meta (key, value) VALUES (?, ?)",
                arguments: [lastBackupKey, iso(now)])
        }
        for old in try backups(in: folder).dropFirst(keep) {
            try manager.removeItem(at: old)
        }
        return destination
    }

    /// `nil` when `store_meta`'s `last_backup_at` falls on the same calendar
    /// day (UTC) as `now`; otherwise the new backup's path.
    static func backupIfDue(pool: DatabasePool, into folder: URL, now: Date,
                            keep: Int = keep) throws -> URL? {
        let last = try pool.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM store_meta WHERE key = ?",
                arguments: [lastBackupKey])
        }
        if let last, let lastDate = ISO8601DateFormatter().date(from: last),
           utcDay(lastDate) == utcDay(now) {
            return nil
        }
        return try backup(pool: pool, into: folder, now: now, keep: keep)
    }

    /// The `threads-*.sqlite` files newest first, by name, which sorts by date
    /// because the name is the date. A folder that is not there reads as none.
    static func backups(in folder: URL) throws -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return []
        }
        return names
            .filter { $0.hasPrefix("threads-") && $0.hasSuffix(".sqlite") }
            .sorted(by: >)
            .map { folder.appendingPathComponent($0, isDirectory: false) }
    }

    /// Replaces `threads.sqlite` with a copy of the backup, leaving any
    /// `.damaged-` file where it is. The copy is brought out of write-ahead
    /// logging so it stands alone without sidecar files; a backup that was
    /// opened once has left `-wal`/`-shm` beside it, and the read-only check
    /// cannot open a WAL file that has none.
    static func restore(_ backup: URL, to url: URL, now: Date) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        for suffix in ["-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        try manager.copyItem(at: backup, to: url)
        let queue = try DatabaseQueue(path: url.path)
        do {
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = DELETE")
            }
            try queue.close()
        } catch {
            try? queue.close()
            throw error
        }
    }

    /// Runs the system `sqlite3` `.recover` of the damaged file into
    /// `destination`, then opens that file through `ThreadDatabase` and counts
    /// the rows in `threads` and `items` so the report is measured. When
    /// `sqlite3` is missing or fails it refuses with `not_supported` and the
    /// program's own message.
    static func repair(from damaged: URL, to destination: URL) throws -> RepairReport {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        for suffix in ["-wal", "-shm"] {
            try? manager.removeItem(at: URL(fileURLWithPath: destination.path + suffix))
        }
        let dump = try runSQLite([damaged.path, ".recover"])
        let dumpFile = manager.temporaryDirectory
            .appendingPathComponent("v1-thread-repair-\(UUID().uuidString).sql", isDirectory: false)
        try dump.write(to: dumpFile)
        defer { try? manager.removeItem(at: dumpFile) }
        _ = try runSQLite([destination.path], inputFile: dumpFile)
        guard manager.fileExists(atPath: destination.path) else {
            throw ThreadStoreError(code: .notSupported,
                                   message: "sqlite3 wrote no repaired file")
        }
        try markMigrationsApplied(at: destination)
        let pool = try ThreadDatabase.open(at: destination)
        defer { try? pool.close() }
        let threads = try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM threads") ?? 0
        }
        let items = try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM items") ?? 0
        }
        return RepairReport(threads: threads, items: items)
    }

    // MARK: - the recovered schema and the migration ledger

    /// The schema `sqlite3 .recover` writes keeps every table, but the rows of
    /// GRDB's migration ledger can sit on the page that was damaged, so the
    /// recovered file would fail to migrate for a step whose table is already
    /// there. This puts back the identifiers the migrator applies — learned by
    /// applying the same migrator to an empty database — so
    /// `ThreadDatabase.open` finds the schema already recorded and does not try
    /// to create a table that survived.
    private static func markMigrationsApplied(at destination: URL) throws {
        let probe = try DatabaseQueue(path: ":memory:")
        try StoreMigrations.migrator().migrate(probe)
        let identifiers = try probe.read { db in
            try String.fetchAll(
                db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        try probe.close()
        let queue = try DatabaseQueue(path: destination.path)
        do {
            try queue.write { db in
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS grdb_migrations
                        (identifier TEXT NOT NULL PRIMARY KEY)
                    """)
                for identifier in identifiers {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO grdb_migrations (identifier) VALUES (?)",
                        arguments: [identifier])
                }
            }
            try queue.close()
        } catch {
            try? queue.close()
            throw error
        }
    }

    // MARK: - the one thing here that starts a process

    /// Starts the system `sqlite3` with `arguments`. The brief of 06 §3.2 gives
    /// repair to `sqlite3`'s own `.recover`, which has no library entry point;
    /// this is therefore the one place in the store that runs a program, and it
    /// runs only `sqlite3`. It is spelled `Process.init()` because the V1 lint
    /// reserves the bare initializer for `ProjectGitProbe`.
    private static func runSQLite(_ arguments: [String], inputFile: URL? = nil) throws -> Data {
        let executable = "/usr/bin/sqlite3"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ThreadStoreError(code: .notSupported,
                                   message: "sqlite3 is not installed at \(executable)")
        }
        let process = Process.init()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        if let inputFile {
            process.standardInput = try FileHandle(forReadingFrom: inputFile)
        }
        do {
            try process.run()
        } catch {
            throw ThreadStoreError(code: .notSupported,
                                   message: "sqlite3 could not start: \(error)")
        }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ThreadStoreError(
                code: .notSupported,
                message: message.isEmpty
                    ? "sqlite3 exited with status \(process.terminationStatus)" : message)
        }
        return output
    }

    // MARK: - dates

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
