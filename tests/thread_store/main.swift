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

// The full-text module the thread store needs is in the system SQLite. The
// claim is anchored outside the code that makes it: this check creates a
// full-text table of its own against the same pool, so a system SQLite without
// the module fails here instead of being taken on the report's word.
do {
    try pool.write { db in
        try db.execute(sql: "CREATE VIRTUAL TABLE temp.vf_fts5_anchor USING fts5(text)")
        try db.execute(sql: "DROP TABLE temp.vf_fts5_anchor")
    }
} catch {
    FileHandle.standardError.write(Data("not ok - the system SQLite has no FTS5: \(error)\n".utf8))
    exit(1)
}
guard report.contains("FTS5 available") else {
    FileHandle.standardError.write(Data("not ok - the report does not say FTS5 is available: \(report)\n".utf8))
    exit(1)
}

// And the report must reach that conclusion by asking SQLite rather than by
// printing a constant: a traced pool records every statement it runs, and one
// of the ones describe() runs has to create a full-text table.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    func add(_ sql: String) { lock.lock(); statements.append(sql); lock.unlock() }
    func sawFullTextTable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return statements.contains { $0.lowercased().contains("using fts5") }
    }
}
let recorder = Recorder()
var tracedConfiguration = Configuration()
tracedConfiguration.prepareDatabase { db in
    db.trace { event in
        if case let .statement(statement) = event { recorder.add(statement.sql) }
    }
}
let tracedPool = try DatabasePool(path: url.path, configuration: tracedConfiguration)
_ = try ThreadDatabase.describe(tracedPool)
guard recorder.sawFullTextTable() else {
    FileHandle.standardError.write(
        Data("not ok - describe() reports on FTS5 without ever asking SQLite for it\n".utf8))
    exit(1)
}

// The report must be able to say otherwise, so it is not a fixed string.
guard report.contains("SQLite 3.") else {
    FileHandle.standardError.write(Data("not ok - the report does not carry a real SQLite version: \(report)\n".utf8))
    exit(1)
}

// shared() is the one line that keeps the running app off the owner's data: it
// opens the file inside the configuration root, which a QA build or a test
// moves with VOICE_FLOW_CONFIG_ROOT. Nothing else in this check goes through
// it, so a shared() that ignored the variable would never be noticed here.
guard VoiceFlowPaths.shared.isIsolated else {
    FileHandle.standardError.write(
        Data("not ok - this check must run with VOICE_FLOW_CONFIG_ROOT set to a throwaway directory\n".utf8))
    exit(1)
}
let sharedPool = try ThreadDatabase.shared()
let sharedFile = URL(fileURLWithPath: sharedPool.path).standardizedFileURL
guard VoiceFlowPaths.shared.contains(sharedFile),
      sharedFile == ThreadDatabase.url(configRoot: VoiceFlowPaths.shared.configRoot).standardizedFileURL else {
    FileHandle.standardError.write(
        Data("not ok - shared() opened \(sharedFile.path), which is not the file in the configuration root\n".utf8))
    exit(1)
}
guard try ThreadDatabase.shared() === sharedPool else {
    FileHandle.standardError.write(Data("not ok - shared() opened the file twice\n".utf8))
    exit(1)
}

print("thread store: \(applied.count) migration(s), one file at \(url.lastPathComponent), "
    + "shared() inside \(VoiceFlowPaths.shared.configRoot.lastPathComponent)")
