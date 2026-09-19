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
let applied = (try? pool.read { db in try StoreMigrations.migrator().appliedIdentifiers(db) }) ?? []
expect(applied.contains { $0.hasSuffix("persona records") },
       "the shared migrator registers the persona records step, applied: \(applied.sorted())")
expect(applied.count >= 2,
       "the persona records step is added beside the steps already there, not in place of them")
expect(PersonaRecordsMigration.tableName == "persona_records", "the table is persona_records")

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
expect(all.map(\.id) == ["flora", "scout"],
       "all() reads every stored row in UTF-8 order of the id, got \(all.map(\.id))")
expect(all.first { $0.id == "scout" }?.deletedAt == "2026-09-19T00:00:00.000Z",
       "all() includes a deleted record")
expect((try? recordStore.record(id: "scout"))?.instructions == "B changed",
       "record(id:) reads one row")
expect((try? recordStore.record(id: "missing")) == nil, "an unknown id answers nil")

// The row is the record's JSON, and the key columns are the record's own facts.
let storedRow = (try? pool.read { db in
    try Row.fetchOne(db, sql: "SELECT home_id, record, fingerprint, deleted_at FROM persona_records"
                     + " WHERE home_id = ? AND id = ?", arguments: ["home-test", "scout"])
}) ?? nil
if let storedRow,
   let storedJSON = storedRow["record"] as? String,
   let decoded = try? JSONDecoder().decode(TPPersona.self, from: Data(storedJSON.utf8)) {
    expect(storedRow["home_id"] as? String == "home-test", "home_id is the record's homeId")
    expect(storedRow["deleted_at"] as? String == "2026-09-19T00:00:00.000Z",
           "deleted_at is the record's deletedAt")
    expect(storedRow["fingerprint"] as? String == PersonaRecordStore.fingerprint(of: decoded),
           "the fingerprint column is the fingerprint of the stored record")
    expect(decoded.instructions == "B changed", "the record column holds the JSON of the record")
    expect(decoded.version == firstVersion + 2, "the stored JSON carries the stored version")
} else {
    expect(false, "persona_records holds one row per record with its JSON")
}

if failures == 0 {
    print("persona records tests passed")
} else {
    fputs("\(failures) persona records checks failed\n", stderr)
    exit(1)
}
