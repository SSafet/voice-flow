import Foundation
import GRDB

// The persona record in threads.sqlite (06 §3.2, §3.4; 11 §3.4): the migration
// the shared migrator registers, the fingerprint that decides whether a record
// version rises, and the factory that carries a changed record forward.

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if condition() {
        print("ok   \(message)")
    } else {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func makeRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("voice-flow-persona-records-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeRecord(id: String = "flora", instructions: String = "A",
                        coreMemory: String = "", skill: Bool = false,
                        delegate: Bool = false, version: Int = 1,
                        deletedAt: String? = nil) -> TPPersona {
    var object: [String: Any] = [
        "id": id, "homeId": "home-test", "name": "FLORA",
        "instructions": instructions, "coreMemory": coreMemory,
        "skills": skill ? [["name": "tickets", "description": "file tickets"]] : [],
        "delegates": delegate ? [["id": "scout", "name": "Scout", "private": true]] : [],
        "isDefault": false, "usable": true, "issues": [], "revision": "abc", "version": version,
    ]
    if let deletedAt { object["deletedAt"] = deletedAt }
    let data = try! JSONSerialization.data(withJSONObject: object)
    return try! JSONDecoder().decode(TPPersona.self, from: data)
}

// ── the migration ────────────────────────────────────────

let configRoot = makeRoot()
guard let pool = try? ThreadDatabase.open(at: ThreadDatabase.url(configRoot: configRoot)) else {
    fputs("FAIL: threads.sqlite could not be opened\n", stderr)
    exit(1)
}
expect(try? pool.read { db in try StoreMigrations.migrator().appliedIdentifiers(db) } != nil,
       "the shared migrator runs against threads.sqlite")

let columns = (try? pool.read { db in
    try Row.fetchAll(db, sql: "PRAGMA table_info(persona_records)")
}) ?? []
let columnNames = columns.compactMap { $0["name"] as? String }
for column in ["id", "home_id", "record", "fingerprint", "version", "deleted_at"] {
    expect(columnNames.contains(column), "persona_records has the \(column) column")
}
let primaryKeys = columns
    .filter { (($0["pk"] as? Int64) ?? 0) != 0 }
    .compactMap { $0["name"] as? String }
expect(primaryKeys == ["home_id", "id"],
       "persona_records is keyed by (home_id, id), got \(primaryKeys)")

// Migrating twice leaves the table and its rows alone.
let recordStore = PersonaRecordStore(database: pool)
_ = try? recordStore.upsert(makeRecord())
let beforeSecondMigrate = (try? recordStore.all().count) ?? 0
try? StoreMigrations.migrator().migrate(pool)
expect((try? recordStore.all().count) == beforeSecondMigrate,
       "running the migrator again does not lose rows")

// ── the fingerprint and the version ──────────────────────

let fresh = makeRecord(id: "scout", instructions: "B")
let first = try? recordStore.upsert(fresh)
expect(first?.changed == true, "a new record is a change")
expect(first?.stored.version == 1, "the first stored version is 1, whatever the input said")
let firstVersion = first?.stored.version ?? 0
let again = try? recordStore.upsert(fresh)
expect(again?.changed == false, "re-writing the same content is not a change")
expect(again?.stored.version == firstVersion, "the version does not rise for equal content")

let edited = makeRecord(id: "scout", instructions: "B changed")
let changed = try? recordStore.upsert(edited)
expect(changed?.changed == true, "a changed instruction is a change")
expect(changed?.stored.version == firstVersion + 1, "a change raises the version by one")
expect(changed?.stored.instructions == "B changed", "the stored record carries the new content")

expect(PersonaRecordStore.fingerprint(of: makeRecord(version: 1)) ==
       PersonaRecordStore.fingerprint(of: makeRecord(version: 9)),
       "the fingerprint ignores the version")
expect(PersonaRecordStore.fingerprint(of: makeRecord(instructions: "A")) !=
       PersonaRecordStore.fingerprint(of: makeRecord(instructions: "B")),
       "the fingerprint follows the content")
expect(PersonaRecordStore.fingerprint(of: makeRecord(coreMemory: "x")) !=
       PersonaRecordStore.fingerprint(of: makeRecord(coreMemory: "y")),
       "the fingerprint follows core memory")

// A deletion is a change that keeps the record and records when.
let deleted = makeRecord(id: "scout", instructions: "B changed",
                         deletedAt: "2026-09-19T00:00:00.000Z")
let deletion = try? recordStore.upsert(deleted)
expect(deletion?.changed == true, "setting deletedAt is a change")
expect(deletion?.stored.deletedAt == "2026-09-19T00:00:00.000Z", "the stored record keeps deletedAt")
expect(deletion?.stored.version == firstVersion + 2, "a deletion raises the version once more")

// ── the factory ──────────────────────────────────────────

let bumped = PersonaRecordFactory.bump(makeRecord(version: 1), version: 7, deletedAt: nil)
expect(bumped.version == 7, "the factory sets the version")
expect(bumped.instructions == "A" && bumped.coreMemory == "" && bumped.revision == "abc",
       "the factory keeps every content field")
expect(bumped.deletedAt == nil, "the factory carries no deletedAt by default")

// ── reading back ─────────────────────────────────────────

let all = (try? recordStore.all()) ?? []
expect(Set(all.map(\.id)) == ["flora", "scout"], "all() reads every stored row")
expect(all.first { $0.id == "scout" }?.deletedAt == "2026-09-19T00:00:00.000Z",
       "all() includes a deleted record")
expect((try? recordStore.record(id: "scout"))?.instructions == "B changed",
       "record(id:) reads one row")
expect((try? recordStore.record(id: "missing")) == nil, "an unknown id answers nil")

if failures == 0 {
    print("persona records tests passed")
} else {
    fputs("\(failures) persona records checks failed\n", stderr)
    exit(1)
}
