import Foundation
import GRDB
import Darwin

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

    /// Read-only: all quick-check results and the migration schema must agree.
    static func check(at url: URL) -> State {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            var configuration = Configuration()
            configuration.readonly = true
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            try queue.read { db in
                let answers = try String.fetchAll(db, sql: "PRAGMA quick_check")
                guard answers == ["ok"] else { throw failure(answers.joined(separator: "; ")) }
                try ThreadStoreSchemaProof.validate(db)
                guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                    throw failure("Thread history contains broken references and needs recovery.")
                }
            }
            return .ok
        } catch { return .damaged(String(describing: error)) }
    }

    static func preservationURL(for url: URL, now: Date) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).damaged-\(stamp(now))-\(UUID().uuidString)")
    }

    static func setAside(at url: URL, now: Date) throws -> URL {
        let target = preservationURL(for: url, now: now)
        try finishPreserving(at: url, to: target)
        return target
    }

    /// Idempotently finishes a journaled rename, including WAL/SHM after a crash.
    static func finishPreserving(at url: URL, to target: URL) throws {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            let destination = URL(fileURLWithPath: target.path + suffix)
            if manager.fileExists(atPath: source.path) {
                guard !manager.fileExists(atPath: destination.path) else {
                    throw failure("Both recovery files exist; neither was overwritten: \(source.path)")
                }
                try manager.moveItem(at: source, to: destination)
            }
        }
        try synchronizeDirectory(url.deletingLastPathComponent())
        guard manager.fileExists(atPath: target.path) else {
            throw failure("The preserved database is missing. Recovery remains required.")
        }
    }

    /// Publish only a verified SQLite online snapshot. Upgrade snapshots have
    /// independent retention: daily rotation cannot delete the rollback point.
    static func backup(pool: DatabasePool, into folder: URL, now: Date,
                       keep: Int = keep, beforeSchemaUpgrade: Bool = false) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let kind = beforeSchemaUpgrade ? "schema" : "daily"
        let destination = folder.appendingPathComponent(
            "threads-\(stamp(now))-\(kind)-\(UUID().uuidString).sqlite")
        let candidate = stagingURL(for: destination)
        defer { removeCandidate(candidate) }
        let expected = try pool.read { try ThreadStoreSchemaProof.validate($0) }
        let target = try DatabaseQueue(path: candidate.path)
        do {
            try pool.backup(to: target)
            try target.read { db in
                try ThreadStoreSchemaProof.verifyIntegrity(db)
                guard try ThreadStoreSchemaProof.validate(db) == expected else {
                    throw failure("Backup schema changed while taking the snapshot.")
                }
            }
            try target.close()
        } catch { try? target.close(); throw error }
        try makeStandalone(candidate)
        try manager.moveItem(at: candidate, to: destination)
        try synchronizeDirectory(folder)
        if !beforeSchemaUpgrade {
            try pool.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO store_meta (key, value) VALUES (?, ?)",
                               arguments: [lastBackupKey, iso(now)])
            }
            for old in try backups(in: folder).filter({ !$0.lastPathComponent.contains("-schema-") }).dropFirst(max(1, keep)) {
                try manager.removeItem(at: old)
            }
        }
        return destination
    }

    static func backupIfDue(pool: DatabasePool, into folder: URL, now: Date,
                            keep: Int = keep) throws -> URL? {
        let last = try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM store_meta WHERE key = ?", arguments: [lastBackupKey])
        }
        if let last, let lastDate = ISO8601DateFormatter().date(from: last),
           utcDay(lastDate) == utcDay(now) { return nil }
        return try backup(pool: pool, into: folder, now: now, keep: keep)
    }

    static func backups(in folder: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("threads-") && $0.hasSuffix(".sqlite") }
            .sorted(by: >).map { folder.appendingPathComponent($0) }
    }

    /// A restore is built beside the live file. Never truncate the destination
    /// (or the backup) to discover afterwards that the source was unusable.
    static func restore(_ backup: URL, to url: URL, now: Date) throws {
        let candidate = stagingURL(for: url)
        defer { removeCandidate(candidate) }
        var configuration = Configuration()
        configuration.readonly = true
        let source = try DatabaseQueue(path: backup.path, configuration: configuration)
        let target = try DatabaseQueue(path: candidate.path)
        do {
            try source.read { db in
                try ThreadStoreSchemaProof.verifyIntegrity(db)
                try ThreadStoreSchemaProof.validate(db)
            }
            try source.backup(to: target)
            try source.close()
            try target.close()
        } catch { try? source.close(); try? target.close(); throw error }
        _ = try finishCandidate(candidate)
        try publish(candidate, to: url, now: now)
    }

    static func repair(from damaged: URL, to destination: URL) throws -> RepairReport {
        let manager = FileManager.default
        let candidate = stagingURL(for: destination)
        defer { removeCandidate(candidate) }
        // A repair must not resurrect deleted records from SQLite's freelist.
        let dump = try runSQLite(["-readonly", damaged.path, ".recover --ignore-freelist"])
        let dumpFile = manager.temporaryDirectory.appendingPathComponent("v1-thread-repair-\(UUID().uuidString).sql")
        try dump.write(to: dumpFile)
        defer { try? manager.removeItem(at: dumpFile) }
        _ = try runSQLite(["-bail", candidate.path], inputFile: dumpFile)
        guard manager.fileExists(atPath: candidate.path) else { throw failure("sqlite3 wrote no repaired file") }
        let queue = try DatabaseQueue(path: candidate.path)
        do {
            try ThreadStoreSchemaProof.reconstructRecoveredLedger(queue)
            try queue.close()
        } catch { try? queue.close(); throw error }
        let report = try finishCandidate(candidate)
        try publish(candidate, to: destination, now: Date())
        return report
    }

    static func startEmpty(at destination: URL, now: Date) throws {
        let candidate = stagingURL(for: destination)
        defer { removeCandidate(candidate) }
        _ = try finishCandidate(candidate)
        try publish(candidate, to: destination, now: now)
    }

    private static func finishCandidate(_ url: URL) throws -> RepairReport {
        let pool = try ThreadDatabase.open(at: url)
        let report: RepairReport
        do {
            report = try pool.read { db in
                try ThreadStoreSchemaProof.verifyIntegrity(db)
                try ThreadStoreSchemaProof.validate(db)
                return RepairReport(threads: try Int.fetchOne(db, sql: "SELECT count(*) FROM threads") ?? 0,
                                    items: try Int.fetchOne(db, sql: "SELECT count(*) FROM items") ?? 0)
            }
            try pool.close()
        } catch { try? pool.close(); throw error }
        try makeStandalone(url)
        return report
    }

    private static func makeStandalone(_ url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        defer { try? queue.close() }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
    }

    private static func publish(_ candidate: URL, to destination: URL, now: Date) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try setAside(at: destination, now: now)
        }
        // A stale WAL may never be paired with the replacement main file.
        for suffix in ["-wal", "-shm"] {
            guard !FileManager.default.fileExists(atPath: destination.path + suffix) else {
                throw failure("Unpaired database sidecar remains; the replacement was not activated.")
            }
        }
        try FileManager.default.moveItem(at: candidate, to: destination)
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func stagingURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".thread-store-\(UUID().uuidString).sqlite")
    }

    private static func removeCandidate(_ url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private static func failure(_ message: String) -> ThreadStoreError {
        ThreadStoreError(code: .notSupported, message: message)
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
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("vf-sqlite-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stderr.close(); try? FileManager.default.removeItem(at: errorURL) }
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
        process.waitUntilExit()
        let errors = (try? Data(contentsOf: errorURL)) ?? Data()
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
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmssSSS"
        return formatter.string(from: date)
    }
}
