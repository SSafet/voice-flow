import Foundation
import GRDB

// The one SQLite file this Mac keeps. It is created inside the configuration
// root and nowhere else, GRDB brings it up to date, and the system SQLite has
// the full-text module the thread store will need.

let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vf-thread-store-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }

let url = ThreadDatabase.url(configRoot: root)
guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
    FileHandle.standardError.write(Data("not ok - the file is inside the configuration root\n".utf8))
    exit(1)
}

let pool = try ThreadDatabase.open(at: url)
let report = try ThreadDatabase.describe(pool)
print(report)

guard FileManager.default.fileExists(atPath: url.path) else {
    FileHandle.standardError.write(Data("not ok - threads.sqlite was created\n".utf8))
    exit(1)
}

// Write-ahead-log mode, so readers never block the writer.
let mode = try pool.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "" }
guard mode.lowercased() == "wal" else {
    FileHandle.standardError.write(Data("not ok - journal mode is \(mode), not wal\n".utf8))
    exit(1)
}

// The migrator ran, and running it again changes nothing.
let applied = try pool.read { db in try StoreMigrations.migrator().appliedIdentifiers(db) }
guard !applied.isEmpty else {
    FileHandle.standardError.write(Data("not ok - no migration was applied\n".utf8))
    exit(1)
}
try StoreMigrations.migrator().migrate(pool)
let again = try pool.read { db in try StoreMigrations.migrator().appliedIdentifiers(db) }
guard again == applied else {
    FileHandle.standardError.write(Data("not ok - migrating twice applied something twice\n".utf8))
    exit(1)
}

// The full-text module the thread store needs is in the system SQLite.
guard report.contains("FTS5 available") else {
    FileHandle.standardError.write(Data("not ok - the report does not say FTS5 is available: \(report)\n".utf8))
    exit(1)
}

// The report must be able to say otherwise, so it is not a fixed string.
guard report.contains("SQLite 3.") else {
    FileHandle.standardError.write(Data("not ok - the report does not carry a real SQLite version: \(report)\n".utf8))
    exit(1)
}

print("thread store: \(applied.count) migration(s), one file at \(url.lastPathComponent)")
