import Foundation
import SQLite3

struct CloudLocalRecord: Codable {
    var collection: CloudCollection
    var recordId: String
    var payload: CloudPayload?
    var lastLivePayload: CloudPayload?
    var remote: CloudRecord?
    var pending: [CloudOperation] = []
    var conflicts: [CloudConflict] = []
    /// Superseded unsent edits are retained for recovery when a person resolves
    /// a conflict; they are never retried as if still canonical.
    var retainedProposals: [CloudOperation] = []
    var blocked: Bool = false
}
struct CloudAccountState: Codable {
    var records: [String: CloudLocalRecord] = [:]
    var cursor: String?
    var epoch: String?
    var appliedSequence: String = "0"
    var imported: Bool = false
    var requiresBaselineReview: Bool = false
    var lastSuccess: String?
    var exports: CloudExportSelection?
    var pendingCount: Int { records.values.reduce(0) { $0 + $1.pending.count } }
    var conflicts: [CloudConflict] { records.values.flatMap { $0.conflicts } }
}

/// SQLite commits the portable local value and immutable outbox together. A
/// page and cursor share the same transaction. Canonical runtime JSON files
/// remain compatibility projections and never store transport credentials.
final class CloudSyncStore {
    private let db: OpaquePointer
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else { throw CloudSyncError.storage("open") }
        db = handle
        sqlite3_busy_timeout(db, 5_000)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS cloud_accounts (partition TEXT PRIMARY KEY, version INTEGER NOT NULL CHECK(version=1), state TEXT NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS cloud_source_owners (record_key TEXT PRIMARY KEY, partition TEXT NOT NULL)")
        } catch { sqlite3_close(db); throw error }
    }
    deinit { sqlite3_close(db) }
    static func partition(origin: String, userID: String) -> String { "\(origin)|\(userID)" }
    static func key(_ collection: CloudCollection, _ id: String) -> String { "\(collection.rawValue):\(id)" }

    func state(_ partition: String) throws -> CloudAccountState {
        try lock.withLock { try readState(partition) }
    }
    func sourceBelongsTo(_ partition: String, collection: CloudCollection, id: String) throws -> Bool {
        if collection == .preferences { return true }
        return try lock.withLock { try sourceOwner(Self.key(collection, id)) == partition }
    }
    func hasImportedAccount() throws -> Bool {
        try lock.withLock {
            try query("SELECT state FROM cloud_accounts", []).contains {
                try JSONDecoder().decode(CloudAccountState.self, from: Data($0.utf8)).imported
            }
        }
    }

    /// Called before saving the legacy projection. Existing source ownership
    /// survives sign-out/account changes: an edit queues for its original
    /// account and cannot be uploaded by whichever account signs in next.
    func capture(_ edits: [CloudLocalEdit], partition: String, markImported: Bool = false, initialImport: Bool = false) throws {
        for edit in edits {
            guard CloudWire.validID(edit.recordId) else { throw CloudSyncError.invalidRecord }
            try edit.payload?.validate(for: edit.collection, id: edit.recordId)
        }
        try transaction {
            var states: [String: CloudAccountState] = [:]
            for edit in edits {
                let key = Self.key(edit.collection, edit.recordId)
                // A newly appended message has no record owner yet. Its
                // existing native conversation still belongs to the account
                // that captured that thread, even after a different sign-in.
                let threadOwner = try edit.collection == .messages
                    ? edit.payload?.threadId.flatMap { try sourceOwner(Self.key(.threads, $0)) } : nil
                let owner = try edit.collection == .preferences ? partition : (sourceOwner(key) ?? threadOwner ?? partition)
                if states[owner] == nil { states[owner] = try readState(owner) }
                var state = states[owner]!
                var row = state.records[key] ?? CloudLocalRecord(collection: edit.collection, recordId: edit.recordId, payload: nil)
                // A missing local projection is not a deletion. Callers pass a
                // nil payload only for an explicit user delete operation.
                if row.payload != edit.payload || (state.records[key] == nil && edit.payload != nil) {
                    let base = try row.pending.last.map { try CloudWire.version($0.baseVersion) + 1 }
                        ?? (initialImport ? 0 : row.remote.map { try CloudWire.version($0.version) } ?? 0)
                    let operation = CloudOperation(collection: edit.collection, recordId: edit.recordId,
                        baseVersion: String(base), op: edit.payload == nil ? "delete" : (edit.restore ? "restore" : "put"), payload: edit.payload)
                    row.payload = edit.payload
                    if let payload = edit.payload { row.lastLivePayload = payload }
                    row.pending.append(operation)
                    state.records[key] = row
                }
                states[owner] = state
                try claim(key, partition: owner)
            }
            if markImported {
                var state = try states[partition] ?? readState(partition)
                state.imported = true
                states[partition] = state
            }
            for (owner, state) in states { try writeState(state, partition: owner) }
        }
    }

    /// Only one operation per record may be in flight. A later edit never
    /// changes the bytes/identity of an already sent operation.
    func nextOperations(_ partition: String, limit: Int = 50) throws -> [CloudOperation] {
        let state = try state(partition)
        if state.requiresBaselineReview { throw CloudSyncError.historyChanged }
        var result: [CloudOperation] = []
        var bytes = 0
        for key in state.records.keys.sorted() {
            guard let row = state.records[key], (state.exports ?? CloudExportSelection()).includes(row.collection),
                  !row.blocked, let operation = row.pending.first else { continue }
            let size = try JSONEncoder().encode(operation).count
            if !result.isEmpty && (bytes + size > 900_000 || result.count >= min(limit, 100)) { break }
            bytes += size
            result.append(operation)
        }
        return result
    }

    func acknowledge(_ receipts: [CloudReceipt], sent: [CloudOperation], partition: String) throws {
        guard Set(sent.map { $0.operationId }).count == sent.count,
              receipts.count == sent.count, Set(receipts.map { $0.operationId }).count == sent.count else { throw CloudSyncError.invalidResponse }
        let sentByID = Dictionary(uniqueKeysWithValues: sent.map { ($0.operationId, $0) })
        try transaction {
            var state = try readState(partition)
            for receipt in receipts {
                guard let operation = sentByID[receipt.operationId] else { throw CloudSyncError.invalidResponse }
                let key = Self.key(operation.collection, operation.recordId)
                guard var row = state.records[key] else { throw CloudSyncError.invalidResponse }
                // Replayed receipt after a local commit is harmless, including
                // when a later local edit is already waiting behind it.
                guard row.pending.contains(where: { $0.operationId == operation.operationId }) else { continue }
                if receipt.status == "applied", let remote = receipt.record,
                   remote.collection == operation.collection, remote.recordId == operation.recordId,
                   remote.seq == receipt.seq,
                   try CloudWire.version(remote.version) == CloudWire.version(operation.baseVersion) + 1,
                   remote.payload == operation.payload,
                   (remote.deletedAt != nil) == (operation.op == "delete") {
                    try validate(remote)
                    row.pending.removeAll { $0.operationId == operation.operationId }
                    if let conflictID = operation.resolvesConflictId { row.conflicts.removeAll { $0.conflictId == conflictID } }
                    try accept(remote, into: &row)
                    row.blocked = !row.conflicts.isEmpty
                } else if receipt.status == "conflict", let conflict = receipt.conflict,
                          conflict.proposed == operation {
                    row.pending.removeAll { $0.operationId == operation.operationId }
                    add(conflict, into: &row)
                } else { throw CloudSyncError.invalidResponse }
                state.records[key] = row
            }
            try writeState(state, partition: partition)
        }
    }

    func apply(_ page: CloudPage, partition: String) throws {
        try transaction {
            var state = try readState(partition)
            if let epoch = state.epoch, epoch != page.epoch { throw CloudSyncError.historyChanged }
            var sequence = try CloudWire.version(state.appliedSequence)
            let upper = try CloudWire.version(page.highWatermark)
            for change in page.changes {
                let next = try CloudWire.version(change.seq)
                if next <= sequence { continue } // a page replay never moves backward
                guard next == sequence + 1, next <= upper else { throw CloudSyncError.invalidResponse }
                let key: String
                if change.kind == "record", let remote = change.record, remote.seq == change.seq {
                    try validate(remote)
                    key = Self.key(remote.collection, remote.recordId)
                    var row = state.records[key] ?? CloudLocalRecord(collection: remote.collection, recordId: remote.recordId, payload: nil)
                    if let resolved = change.resolvedConflictId { row.conflicts.removeAll { $0.conflictId == resolved } }
                    row.blocked = !row.conflicts.isEmpty
                    try accept(remote, into: &row)
                    state.records[key] = row
                } else if change.kind == "conflict", let conflict = change.conflict {
                    key = Self.key(conflict.collection, conflict.recordId)
                    var row = state.records[key] ?? CloudLocalRecord(collection: conflict.collection, recordId: conflict.recordId, payload: nil)
                    add(conflict, into: &row)
                    state.records[key] = row
                } else { throw CloudSyncError.invalidResponse }
                try claim(key, partition: partition)
                sequence = next
            }
            guard !page.nextCursor.isEmpty, !page.hasMore || sequence < upper,
                  page.hasMore || sequence == upper else { throw CloudSyncError.invalidResponse }
            state.cursor = page.nextCursor
            state.epoch = page.epoch
            state.appliedSequence = String(sequence)
            state.lastSuccess = CloudWire.timestamp()
            try writeState(state, partition: partition)
        }
    }

    func requireBaselineReview(_ partition: String) throws {
        try transaction { var state = try readState(partition); state.requiresBaselineReview = true; try writeState(state, partition: partition) }
    }
    func setExports(_ selection: CloudExportSelection, partition: String) throws {
        try transaction {
            var state = try readState(partition)
            let previous = state.exports ?? CloudExportSelection()
            if CloudCollection.allCases.contains(where: { selection.includes($0) && !previous.includes($0) }) { state.imported = false }
            state.exports = selection
            try writeState(state, partition: partition)
        }
    }
    /// Explicit recovery keeps pending edits and conflict copies, resets only
    /// the remote cursor/baseline, and lets CAS expose changed cloud history.
    func resetBaseline(_ partition: String) throws {
        try transaction {
            var state = try readState(partition)
            state.cursor = nil; state.epoch = nil; state.appliedSequence = "0"; state.requiresBaselineReview = false
            for key in Array(state.records.keys) { state.records[key]?.remote = nil }
            try writeState(state, partition: partition)
        }
    }

    enum ResolutionChoice { case local, cloud, proposal }
    func resolve(_ conflict: CloudConflict, remote: CloudRecord, choice: ResolutionChoice, partition: String) throws {
        try validate(remote)
        guard remote.collection == conflict.collection, remote.recordId == conflict.recordId else { throw CloudSyncError.invalidResponse }
        try transaction {
            var state = try readState(partition)
            let key = Self.key(conflict.collection, conflict.recordId)
            guard var row = state.records[key], row.conflicts.contains(where: { $0.conflictId == conflict.conflictId }) else { throw CloudSyncError.invalidResponse }
            let chosen: CloudPayload?
            switch choice {
            case .local: chosen = row.payload
            case .cloud: chosen = remote.payload
            case .proposal: chosen = conflict.proposed.payload
            }
            row.retainedProposals.append(contentsOf: row.pending)
            row.pending = [CloudOperation(collection: conflict.collection, recordId: conflict.recordId,
                baseVersion: remote.version, op: chosen == nil ? "delete" : (remote.deletedAt == nil ? "put" : "restore"),
                payload: chosen, resolvesConflictId: conflict.conflictId)]
            row.payload = chosen; row.remote = remote; row.blocked = false
            state.records[key] = row
            try writeState(state, partition: partition)
        }
    }

    private func validate(_ record: CloudRecord) throws {
        guard record.schemaVersion == 1, CloudWire.validID(record.recordId),
              try CloudWire.version(record.version) > 0 else { throw CloudSyncError.updateRequired }
        _ = try CloudWire.version(record.seq)
        guard (record.deletedAt == nil) == (record.payload != nil) else { throw CloudSyncError.invalidResponse }
        try record.payload?.validate(for: record.collection, id: record.recordId)
    }
    private func accept(_ remote: CloudRecord, into row: inout CloudLocalRecord) throws {
        if let current = row.remote, try CloudWire.version(current.version) > CloudWire.version(remote.version) { return }
        row.remote = remote
        if row.pending.isEmpty && !row.blocked {
            row.payload = remote.payload
            if let payload = remote.payload { row.lastLivePayload = payload }
        }
    }
    private func add(_ conflict: CloudConflict, into row: inout CloudLocalRecord) {
        if !row.conflicts.contains(where: { $0.conflictId == conflict.conflictId }) { row.conflicts.append(conflict) }
        row.blocked = true
    }
    private func sourceOwner(_ key: String) throws -> String? {
        try query("SELECT partition FROM cloud_source_owners WHERE record_key=?", [key]).first
    }
    private func claim(_ key: String, partition: String) throws {
        try execute("INSERT OR IGNORE INTO cloud_source_owners(record_key,partition) VALUES(?,?)", [key, partition])
    }
    private func readState(_ partition: String) throws -> CloudAccountState {
        guard let json = try query("SELECT state FROM cloud_accounts WHERE partition=?", [partition]).first else { return CloudAccountState() }
        do { return try JSONDecoder().decode(CloudAccountState.self, from: Data(json.utf8)) }
        catch { throw CloudSyncError.storage("decode") }
    }
    private func writeState(_ state: CloudAccountState, partition: String) throws {
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try execute("INSERT INTO cloud_accounts(partition,version,state) VALUES(?,1,?) ON CONFLICT(partition) DO UPDATE SET state=excluded.state", [partition, json])
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do { let result = try body(); try execute("COMMIT"); return result }
            catch { try? execute("ROLLBACK"); throw error }
        }
    }
    private func withStatement<T>(_ sql: String, _ args: [String], _ body: (OpaquePointer) throws -> T) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw CloudSyncError.storage("prepare") }
        defer { sqlite3_finalize(pointer) }
        for (index, value) in args.enumerated() { sqlite3_bind_text(pointer, Int32(index + 1), value, -1, Self.transient) }
        return try body(pointer)
    }
    private func execute(_ sql: String, _ args: [String] = []) throws {
        try withStatement(sql, args) { statement in
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW { result = sqlite3_step(statement) }
            guard result == SQLITE_DONE else { throw CloudSyncError.storage("write") }
        }
    }
    private func query(_ sql: String, _ args: [String]) throws -> [String] {
        try withStatement(sql, args) { statement in
            var rows: [String] = []
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                guard let text = sqlite3_column_text(statement, 0) else { throw CloudSyncError.storage("read") }
                rows.append(String(cString: text)); result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw CloudSyncError.storage("read") }
            return rows
        }
    }
}
