import Foundation
import GRDB

// V1, task 4 — backups, the launch check, damage set aside without overwriting
// anything, and the four ways out (06 §3.2 "Backups", "Damage is surfaced and
// recoverable"; 06 §7; the drill of 06 §8 item 5).

let root = makeConfigRoot("v1-recovery")
defer { try? fixtureFileManager.removeItem(at: root) }

let storeURL = ThreadDatabase.url(configRoot: root)
let backupsFolder = root.appendingPathComponent("backups", isDirectory: true)
let paths = makePaths(root)
var day = Date(timeIntervalSince1970: 1_790_000_000)
func nextDay() -> Date { day = day.addingTimeInterval(86_400); return day }

/// Overwrites part of a database file. The connection must be closed first, or
/// the pages we damage are still cached by the writer.
func damage(_ url: URL, atOffset offset: UInt64, bytes: Int, value: UInt8) throws {
    let handle = try FileHandle(forUpdating: url)
    try handle.seek(toOffset: offset)
    try handle.write(contentsOf: Data(repeating: value, count: bytes))
    try handle.close()
}

func countRows(_ url: URL, _ table: String) throws -> Int {
    let pool = try ThreadDatabase.open(at: url)
    defer { try? pool.close() }
    return try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)") ?? -1 }
}

// ------------------------------------------------------- launch on nothing

require(ThreadStoreHealth.check(at: storeURL) == .absent, "a store that is not there reads as absent")

guard case .ready(let firstPool, let firstReport) = try ThreadStoreLaunch.open(configRoot: root, now: day) else {
    FileHandle.standardError.write(Data("not ok - the first launch must be ready\n".utf8))
    exit(1)
}
require(firstReport.created, "the first launch says the store is new")
require(firstReport.backup == nil, "there is nothing to back up yet")
require(fixtureFileManager.fileExists(atPath: storeURL.path), "the file was made")

// Something worth losing.
let store = ThreadStore(pool: firstPool, paths: paths, homeID: { "h_mac_one" })
try store.upsertProject(makeProject(id: "p_one", name: "Atika", path: root.path))
for n in 1...12 {
    _ = try store.apply([.thread(makeThread(id: "t_\(n)", projectID: "p_one", title: "Thread \(n)"))])
    _ = try store.apply([.itemCompleted(makeItem(id: "i_\(n)", turnID: "turn_\(n)", threadID: "t_\(n)",
                                                 text: "message number \(n)"))])
}
require(try store.threads(includeArchived: true).count == 12, "twelve threads are in the store")
ok("the launch makes the store when it is not there")

// --------------------------------------------------------------- backups

let firstBackup = try ThreadStoreHealth.backup(pool: firstPool, into: backupsFolder, now: day)
require(fixtureFileManager.fileExists(atPath: firstBackup.path), "a backup file was written")
require(firstBackup.lastPathComponent.hasPrefix("threads-")
        && firstBackup.pathExtension == "sqlite",
        "the backup is named threads-<date>.sqlite, as Settings, Storage says")
require(firstBackup.deletingLastPathComponent().standardizedFileURL == backupsFolder.standardizedFileURL,
        "backups live in the backups folder beside the store")

// A backup is a real copy, not an empty file with the right name.
require(try countRows(firstBackup, "threads") == 12,
        "the backup holds the threads that were in the store when it was taken")
require(try countRows(firstBackup, "items") == 12, "and their items")

// Once a day, not once a call.
require(try ThreadStoreHealth.backupIfDue(pool: firstPool, into: backupsFolder, now: day) == nil,
        "a second backup on the same day is not taken")
require(try ThreadStoreHealth.backupIfDue(pool: firstPool, into: backupsFolder, now: nextDay()) != nil,
        "the next day's backup is taken")

// The newest seven are kept.
for _ in 1...8 {
    _ = try ThreadStoreHealth.backupIfDue(pool: firstPool, into: backupsFolder, now: nextDay())
}
let kept = try ThreadStoreHealth.backups(in: backupsFolder)
require(ThreadStoreHealth.keep == 7, "the rule is the newest seven")
require(kept.count == 7, "exactly seven backups are kept")
let names = kept.map(\.lastPathComponent)
require(names == names.sorted(by: >), "backups are listed newest first")
require(!names.contains(firstBackup.lastPathComponent), "the oldest ones were removed")
require(try countRows(kept[0], "threads") == 12, "the newest kept backup still opens and holds the threads")
ok("a backup is a working copy, taken once a day, and the newest seven are kept")

// A launch a day later takes that day's backup by itself, which is what makes
// the rule hold without anything scheduling it.
guard case .ready(let laterPool, let laterReport) = try ThreadStoreLaunch.open(configRoot: root, now: nextDay()) else {
    FileHandle.standardError.write(Data("not ok - the store must still open\n".utf8))
    exit(1)
}
require(!laterReport.created, "the store was already there")
require(laterReport.backup != nil, "a launch on a new day takes the day's backup")
require(try ThreadStoreHealth.backups(in: backupsFolder).count == 7, "and still keeps only seven")
try laterPool.close()
ok("a launch takes the day's backup when one is due")

// --------------------------------------------------------------- damage

try firstPool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
try firstPool.close()

let sizeBefore = try fixtureFileManager.attributesOfItem(atPath: storeURL.path)[.size] as? Int ?? 0
try damage(storeURL, atOffset: 4096, bytes: 4096, value: 0x7f)

guard case .damaged(let reason) = ThreadStoreHealth.check(at: storeURL) else {
    FileHandle.standardError.write(Data("not ok - a damaged file must read as damaged\n".utf8))
    exit(1)
}
require(!reason.isEmpty, "the damage is reported with the reason the check gave")
ok("the launch check finds a damaged file and says why")

guard case .damaged(let damageReport) = try ThreadStoreLaunch.open(configRoot: root, now: day) else {
    FileHandle.standardError.write(Data("not ok - the launch must report damage, not open\n".utf8))
    exit(1)
}
require(!fixtureFileManager.fileExists(atPath: storeURL.path),
        "the damaged file is moved out of the way, not opened")
require(damageReport.setAside.lastPathComponent.hasPrefix("threads.sqlite.damaged-"),
        "it is renamed threads.sqlite.damaged-<timestamp>")
let sizeAfter = try fixtureFileManager.attributesOfItem(atPath: damageReport.setAside.path)[.size] as? Int ?? -1
require(sizeAfter == sizeBefore, "nothing was overwritten: the damaged file is kept whole")
require(damageReport.newestBackup != nil, "the report names the newest backup, for the window's date")
require(!damageReport.reason.isEmpty, "the report carries the reason for the window to show")
ok("a damaged store is set aside untouched and the launch reports it")

// ----------------------------------------------------------- the ways out

let choices = try ThreadStoreRecovery.choices(for: damageReport, configRoot: root)
require(choices.contains(.repair), "try repair is offered")
require(choices.contains(.startEmpty), "start empty is offered")
require(choices.contains(.showInFinder), "show the files in Finder is offered")
require(choices.contains(where: { if case .restoreBackup = $0 { return true }; return false }),
        "restore the newest backup is offered, because there is one")

// Repair: the report must be measured from the file it made, not invented.
let repairedURL = root.appendingPathComponent("threads.repaired.sqlite")
let repairReport = try ThreadStoreHealth.repair(from: damageReport.setAside, to: repairedURL)
require(fixtureFileManager.fileExists(atPath: repairedURL.path), "repair wrote a new file")
require(try repairReport.threads == countRows(repairedURL, "threads"),
        "the repair report counts the threads that are really in the file it made")
require(try repairReport.items == countRows(repairedURL, "items"), "and the items")
ok("repair produces a file that opens and a report measured from it")

// Restore: the threads come back.
try ThreadStoreHealth.restore(damageReport.newestBackup!, to: storeURL, now: day)
guard case .ready(let restoredPool, _) = try ThreadStoreLaunch.open(configRoot: root, now: day) else {
    FileHandle.standardError.write(Data("not ok - the restored store must open\n".utf8))
    exit(1)
}
let restoredStore = ThreadStore(pool: restoredPool, paths: paths, homeID: { "h_mac_one" })
require(try restoredStore.threads(includeArchived: true).count == 12, "the threads are back")
require(try restoredStore.search("message number 3", threadID: nil, limit: 5).count == 1,
        "and so is their history, with the search index")
require(fixtureFileManager.fileExists(atPath: damageReport.setAside.path),
        "the damaged file is still kept after a restore")
try restoredPool.close()
ok("restoring the newest backup brings the threads back")

// Start empty: a new store, and the damaged one still there.
let emptyRoot = makeConfigRoot("v1-recovery-empty")
defer { try? fixtureFileManager.removeItem(at: emptyRoot) }
let emptyURL = ThreadDatabase.url(configRoot: emptyRoot)
let seedPool = try ThreadDatabase.open(at: emptyURL)
try seedPool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
try seedPool.close()
try damage(emptyURL, atOffset: 0, bytes: 2048, value: 0x00)

guard case .damaged(let emptyDamage) = try ThreadStoreLaunch.open(configRoot: emptyRoot, now: day) else {
    FileHandle.standardError.write(Data("not ok - the seeded damage must be reported\n".utf8))
    exit(1)
}
require(emptyDamage.newestBackup == nil, "this store never had a backup")
require(try ThreadStoreRecovery.choices(for: emptyDamage, configRoot: emptyRoot)
        .allSatisfy({ if case .restoreBackup = $0 { return false }; return true }),
        "with no backup, restoring one is not offered")
let started = try ThreadStoreRecovery.apply(.startEmpty, report: emptyDamage,
                                            configRoot: emptyRoot, now: day)
require(started != nil, "starting empty gives a store to work in")
let startedStore = ThreadStore(pool: started!, paths: makePaths(emptyRoot), homeID: { "h_mac_one" })
require(try startedStore.threads(includeArchived: true).isEmpty, "the new store is empty")
require(fixtureFileManager.fileExists(atPath: emptyDamage.setAside.path),
        "the damaged file stays, so nothing is lost by choosing this")
ok("starting empty makes a new store and keeps the damaged one")

print("thread store recovery: backups, the launch check, damage set aside, repair, restore, start empty")
