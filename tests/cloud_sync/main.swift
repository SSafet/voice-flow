import Foundation

func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { fatalError(message) }
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-cloud-sync-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let url = root.appendingPathComponent("cloud.sqlite")
let account = CloudSyncStore.partition(origin: "https://atika.test", userID: "owner-a")
let other = CloudSyncStore.partition(origin: "https://atika.test", userID: "owner-b")
func edit(_ id: String, _ text: String) -> CloudLocalEdit {
    CloudLocalEdit(collection: .dictations, recordId: id, payload: CloudPayload(text: text, destination: "kept"))
}
func remote(_ id: String, _ text: String?, version: String = "1", seq: String = "1") -> CloudRecord {
    CloudRecord(collection: .dictations, recordId: id, version: version, schemaVersion: 1,
                payload: text.map { CloudPayload(text: $0, destination: "kept") },
                deletedAt: text == nil ? CloudWire.timestamp() : nil, seq: seq)
}
func receipt(_ operation: CloudOperation, _ record: CloudRecord) -> CloudReceipt {
    CloudReceipt(operationId: operation.operationId, status: "applied", seq: record.seq, record: record)
}
func page(_ records: [CloudRecord], cursor: String, upper: String, epoch: String = "epoch-a") -> CloudPage {
    CloudPage(changes: records.map { CloudChange(seq: $0.seq, kind: "record", record: $0) },
              nextCursor: cursor, hasMore: false, highWatermark: upper, epoch: epoch, serverTime: CloudWire.timestamp())
}

// One import transaction retains more than both old UI caps. A repeat reuses
// every operation ID; reopening the DB represents process loss/restart.
var store: CloudSyncStore? = try CloudSyncStore(url: url)
let imported = (0..<1200).map { edit("import-\($0)", "Saved offline \($0)") }
try store!.capture(imported, partition: account, markImported: true)
let firstIDs = try store!.state(account).records.values.flatMap { $0.pending.map { $0.operationId } }.sorted()
try store!.capture(imported, partition: account, markImported: true)
store = nil
store = try CloudSyncStore(url: url)
try check(store!.state(account).pendingCount == 1200, "import count survived restart")
try check(store!.state(account).records.values.flatMap { $0.pending.map { $0.operationId } }.sorted() == firstIDs, "import receipt identity survives repeat")
try store!.capture(Array(imported.prefix(200)), partition: account)
try check(store!.state(account).pendingCount == 1200, "UI eviction is not a deletion")

// Native projection from owner A is never imported into owner B. Edits to an
// old locally visible record continue queuing only in their original account.
try store!.capture(imported, partition: other, markImported: true)
try check(store!.state(other).records.isEmpty, "account switch does not upload another account's projection")
try store!.capture([edit("import-0", "Edited while signed into another account")], partition: other)
try check(store!.state(account).records["dictations:import-0"]!.pending.count == 2, "old owner retains offline edit")
try check(store!.state(other).pendingCount == 0, "other account has no old outbox")
try store!.capture([CloudLocalEdit(collection: .threads, recordId: "old-account-thread", payload: CloudPayload(title: "Original account conversation"))], partition: account)
try store!.capture([CloudLocalEdit(collection: .messages, recordId: "new-message-after-switch", payload: CloudPayload(text: "Continued old conversation", threadId: "old-account-thread", role: "user"))], partition: other)
try check(store!.state(account).records["messages:new-message-after-switch"]?.payload?.text == "Continued old conversation", "new messages inherit their original conversation owner")
try check(store!.state(other).pendingCount == 0, "new message cannot split an old conversation across accounts")

// Capture while uploading keeps the later immutable operation queued. A lost
// receipt may be delivered twice, and neither delivery acknowledges that edit.
try store!.capture([edit("race", "first")], partition: account)
let sent = try store!.state(account).records["dictations:race"]!.pending[0]
try store!.capture([edit("race", "second")], partition: account)
let first = remote("race", "first")
try store!.acknowledge([receipt(sent, first)], sent: [sent], partition: account)
try store!.acknowledge([receipt(sent, first)], sent: [sent], partition: account)
var row = try store!.state(account).records["dictations:race"]!
try check(row.pending.count == 1 && row.pending[0].baseVersion == "1", "exact sent-version acknowledgment")
try check(row.payload?.text == "second", "later edit remains visible")
try store!.apply(page([first], cursor: "cursor-1", upper: "1"), partition: account)
try store!.apply(page([first], cursor: "cursor-1", upper: "1"), partition: account)
try check(store!.state(account).records["dictations:race"]!.payload?.text == "second", "pull cannot overwrite newer local content")

// A malformed page fails atomically: even the valid earlier item and cursor
// must not be committed. Epoch changes preserve both local and pending data.
let before = try store!.state(account)
do {
    try store!.apply(page([remote("new", "remote", seq: "2"), remote("gap", "gap", seq: "4")], cursor: "bad", upper: "4"), partition: account)
    fatalError("gap accepted")
} catch CloudSyncError.invalidResponse { }
try check(store!.state(account).records["dictations:new"] == nil, "page transaction rolled back")
try check(store!.state(account).cursor == before.cursor, "cursor did not advance")
do {
    try store!.apply(page([], cursor: "other-epoch", upper: "1", epoch: "restored"), partition: account)
    fatalError("epoch changed silently")
} catch CloudSyncError.historyChanged { }
try check(store!.state(account).pendingCount == before.pendingCount, "epoch failure preserves outbox")

// A rejected proposal blocks the record, but subsequent edits still persist.
let proposed = row.pending[0]
let conflict = CloudConflict(conflictId: "conflict-one", collection: .dictations, recordId: "race",
    baseVersion: "1", currentVersion: "2", proposed: proposed, reason: "version_changed", createdAt: CloudWire.timestamp())
try store!.acknowledge([CloudReceipt(operationId: proposed.operationId, status: "conflict", seq: "3", conflict: conflict)], sent: [proposed], partition: account)
try store!.capture([edit("race", "third edit after conflict")], partition: account)
try check(!store!.nextOperations(account, limit: 100).contains { $0.recordId == "race" }, "conflicted record cannot automatically retry")
let latest = remote("race", "other device", version: "2", seq: "2")
try store!.resolve(conflict, remote: latest, choice: .local, partition: account)
row = try store!.state(account).records["dictations:race"]!
try check(row.pending[0].payload?.text == "third edit after conflict", "resolution uses latest local edit")
try check(row.retainedProposals.count == 1, "superseded draft is retained")
try check(row.pending[0].baseVersion == "2" && row.pending[0].resolvesConflictId == conflict.conflictId, "resolution is explicit CAS")

// Cloud DTOs reject oversized and cross-collection/config shapes locally.
do {
    try store!.capture([edit("too-large", String(repeating: "x", count: 70_000))], partition: account)
    fatalError("oversized record accepted")
} catch CloudSyncError.invalidRecord { }
var crossCollection = CloudPayload(text: "valid", destination: "kept")
crossCollection.value = .text("credential-canary")
do { try crossCollection.validate(for: .dictations, id: "bad"); fatalError("cross-collection field accepted") }
catch CloudSyncError.invalidRecord { }
for invalid in [
    CloudPayload(text: "embedded\0nul", destination: "kept"),
    CloudPayload(text: String(repeating: "a", count: 59_999) + "🦉", destination: "kept"),
    CloudPayload(text: "valid", destination: "kept", createdAt: "2026-09-12T10:20Z"),
    CloudPayload(text: "valid", destination: "kept", legacyTimestamp: "  "),
] {
    do { try invalid.validate(for: .dictations, id: "bad"); fatalError("server-incompatible field accepted") }
    catch CloudSyncError.invalidRecord { }
}
do { try CloudPayload(title: "  ").validate(for: .threads, id: "bad"); fatalError("blank title accepted") }
catch CloudSyncError.invalidRecord { }
do { try CloudPayload(value: .words(["  "])).validate(for: .preferences, id: "vocabulary"); fatalError("blank vocabulary accepted") }
catch CloudSyncError.invalidRecord { }
do { try CloudPayload(value: .text("openai/model\n")).validate(for: .preferences, id: "agent_model"); fatalError("invalid model accepted") }
catch CloudSyncError.invalidRecord { }
try check(!CloudWire.validID("record\n"), "ID validation consumes the entire string")
try check(try CloudWire.origin("https://ATIKA.test/") == "https://atika.test", "origin normalization")
for bad in ["http://atika.test", "https://user:pass@atika.test", "https://atika.test/api", "https://atika.test?token=canary"] {
    do { _ = try CloudWire.origin(bad); fatalError("insecure origin accepted") } catch CloudSyncError.insecureOrigin { }
}
print("PASS cloud sync: 1200-record durable/repeat import, account isolation, exact acknowledgment, concurrent local edit, replay/atomic cursor, epoch, retained conflicts/resolution, strict DTO/origin")

// Export scope is durable per account and filters existing queues without
// discarding their edits. Enabling a new type schedules a conservative import.
let selection = CloudExportSelection(dictations: false, conversations: false, preferences: false)
try store!.setExports(selection, partition: account)
try check(store!.nextOperations(account).isEmpty, "excluded datasets are never sent")
try check(store!.state(account).pendingCount > 0, "turning off export retains pending edits")
try store!.setExports(CloudExportSelection(), partition: account)
try check(!store!.state(account).imported, "reenabling exports requires rechecking native data")
try store!.capture([edit("race", "legacy collision after enabling")], partition: account, initialImport: true)
