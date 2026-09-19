import Foundation
import GRDB

/// One durable event as the store holds it. `origin` is the word `self` on
/// disk and the current home id when it leaves the store; an adopted event
/// keeps the origin it arrived with. Both sequence numbers belong to the
/// transaction that wrote the row.
struct StoredEvent: Equatable {
    let threadID: String
    let seq: Int
    let origin: String
    let originSeq: Int
    let type: TPEventType
    let turnID: String?
    let itemID: String?
    let at: String
    let payload: TPDurableEvent
}

/// One write that belongs together with its event. The event's type and the
/// payload come from the case; the record column comes from the record.
enum ThreadWrite {
    case thread(TPThread)
    case turn(TPTurn)
    case itemStarted(TPItem)
    case itemUpdated(TPItem)
    case itemCompleted(TPItem)
}

/// The channel outbox V9 registers later. It is handed the whole batch inside
/// the store's own transaction, so a sink that throws rolls the write back and
/// the outbox append can never drift from the rows.
protocol ThreadEventSink: AnyObject {
    func append(_ events: [StoredEvent], in db: Database) throws
}

/// An attachment with the two Mac-only facts S4 relinks by.
struct StoredAttachment: Equatable {
    let attachment: TPAttachment
    let itemID: String?
    let localPath: String?
}

/// The pill's native listening state for one item. Mac-only, kept in its own
/// table, never inside a contract record.
struct NativeConsumption: Equatable {
    var threadID: String
    var itemID: String
    var spoken: Bool
    var resumeSentence: String?
    var dismissedFromPill: Bool
    var speakReply: Bool
}

/// What one `thread/open` answer carries: the record, the thread's last
/// number, the newest turns with their items, and the replay when a `sinceSeq`
/// was given.
struct ThreadOpenPage {
    let thread: TPThread
    let lastSeq: Int
    let turns: [TPTurn]
    let items: [TPItem]
    let events: [StoredEvent]
    let hasOlder: Bool
}

/// The single writer of the thread store and every read over it (06 §3.2).
///
/// Every write that belongs together is one GRDB transaction: the row, the
/// event with both sequence numbers, and the outbox append through
/// `ThreadEventSink`. The home's id is never written; rows and payloads carry
/// the word `self` and the current id is put in place when a record leaves the
/// store.
final class ThreadStore {
    let pool: DatabasePool
    let paths: VoiceFlowPaths
    private let homeIDProvider: () -> String
    private let now: () -> Date
    var eventSink: ThreadEventSink?

    init(pool: DatabasePool, paths: VoiceFlowPaths, homeID: @escaping () -> String,
         now: @escaping () -> Date = Date.init) {
        self.pool = pool
        self.paths = paths
        self.homeIDProvider = homeID
        self.now = now
    }

    private var homeID: String { homeIDProvider() }

    // MARK: - writing

    /// Runs one transaction for the whole batch. Each write upserts its row
    /// and its queried columns, takes the next `seq` for the thread and the
    /// next `origin_seq` for this Mac, stores the event, and raises the two
    /// counters. Anything that throws — the sink included — rolls it all back.
    @discardableResult
    func apply(_ writes: [ThreadWrite]) throws -> [StoredEvent] {
        try pool.write { db in
            var stored: [StoredEvent] = []
            for write in writes {
                stored.append(try store(write, in: db))
            }
            if let eventSink {
                try eventSink.append(stored, in: db)
            }
            return stored.map { event in
                StoredEvent(threadID: event.threadID, seq: event.seq,
                            origin: StoreHome.resolve(event.origin, homeID: self.homeID),
                            originSeq: event.originSeq, type: event.type,
                            turnID: event.turnID, itemID: event.itemID, at: event.at,
                            payload: event.payload)
            }
        }
    }

    private func store(_ write: ThreadWrite, in db: Database) throws -> StoredEvent {
        let threadID = write.threadID
        if !write.isThread {
            let exists = try Bool.fetchOne(
                db, sql: "SELECT 1 FROM threads WHERE id = ?", arguments: [threadID]) ?? false
            if !exists {
                throw ThreadStoreError(
                    code: .notFound,
                    message: "no thread \(threadID) to write \(write.eventType.rawValue) for")
            }
        }

        var lastSeq = 0
        var lastOriginSeq = 0
        if let counter = try Row.fetchOne(
            db, sql: "SELECT last_seq, last_origin_seq FROM threads WHERE id = ?",
            arguments: [threadID]) {
            lastSeq = counter["last_seq"]
            lastOriginSeq = counter["last_origin_seq"]
        }

        try writeRecordRow(write, in: db)

        let seq = lastSeq + 1
        let originSeq = lastOriginSeq + 1
        let at = timestamp()
        let payload = write.payload
        let payloadJSON = try ThreadRecords.encode(payload)
        try db.execute(sql: """
            INSERT INTO thread_events
                (thread_id, seq, origin, origin_seq, type, turn_id, item_id, payload, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [threadID, seq, StoreHome.marker, originSeq,
                             write.eventType.rawValue, write.turnID, write.itemID,
                             payloadJSON, at])
        try db.execute(sql: "UPDATE threads SET last_seq = ?, last_origin_seq = ? WHERE id = ?",
                       arguments: [seq, originSeq, threadID])

        return StoredEvent(threadID: threadID, seq: seq, origin: StoreHome.marker,
                           originSeq: originSeq, type: write.eventType, turnID: write.turnID,
                           itemID: write.itemID, at: at, payload: payload)
    }

    private func writeRecordRow(_ write: ThreadWrite, in db: Database) throws {
        switch write {
        case .thread(let thread):
            try upsertThreadRow(thread, in: db)
        case .turn(let turn):
            try upsertTurnRow(turn, in: db)
        case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
            try upsertItemRow(item, in: db)
        }
    }

    private func upsertThreadRow(_ thread: TPThread, in db: Database) throws {
        let record = try ThreadRecords.encode(thread)
        try db.execute(sql: """
            INSERT INTO threads
                (id, project_id, home_id, title, activity, runtime, persona_id,
                 last_activity_at, last_read_at, archived_at, deleted_at, pinned_slot,
                 version, record)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id = excluded.project_id, home_id = excluded.home_id,
                title = excluded.title, activity = excluded.activity,
                runtime = excluded.runtime, persona_id = excluded.persona_id,
                last_activity_at = excluded.last_activity_at,
                last_read_at = excluded.last_read_at, archived_at = excluded.archived_at,
                deleted_at = excluded.deleted_at, pinned_slot = excluded.pinned_slot,
                version = excluded.version, record = excluded.record
            """, arguments: [thread.id, thread.projectID, StoreHome.marker, thread.title,
                             thread.activity.rawValue, thread.runtime.rawValue, thread.personaID,
                             thread.lastActivityAt, thread.lastReadAt, thread.archivedAt,
                             thread.deletedAt, thread.pinnedSlot, thread.version, record])
    }

    private func upsertTurnRow(_ turn: TPTurn, in db: Database) throws {
        let record = try ThreadRecords.encode(turn)
        try db.execute(sql: """
            INSERT INTO turns (id, thread_id, created_at, status, record)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                thread_id = excluded.thread_id, created_at = excluded.created_at,
                status = excluded.status, record = excluded.record
            """, arguments: [turn.id, turn.threadID, turn.createdAt, turn.status.rawValue, record])
    }

    private func upsertItemRow(_ item: TPItem, in db: Database) throws {
        let record = try ThreadRecords.encode(item)
        try db.execute(sql: """
            INSERT INTO items (id, turn_id, thread_id, kind, status, text, created_at, record)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                turn_id = excluded.turn_id, thread_id = excluded.thread_id,
                kind = excluded.kind, status = excluded.status, text = excluded.text,
                created_at = excluded.created_at, record = excluded.record
            """, arguments: [item.id, item.turnID, item.threadID, item.kind.rawValue,
                             item.status.rawValue, item.text, item.createdAt, record])
    }

    func upsertProject(_ project: TPProject) throws {
        try pool.write { db in
            try upsertProjectRow(project, in: db)
        }
    }

    private func upsertProjectRow(_ project: TPProject, in db: Database) throws {
        let record = try ThreadRecords.encode(project)
        try db.execute(sql: """
            INSERT INTO projects
                (id, home_id, name, path, git_remote, git_default_branch, is_general,
                 remote_access, created_at, archived_at, deleted_at, version, record)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                home_id = excluded.home_id, name = excluded.name, path = excluded.path,
                git_remote = excluded.git_remote,
                git_default_branch = excluded.git_default_branch,
                is_general = excluded.is_general, remote_access = excluded.remote_access,
                created_at = excluded.created_at, archived_at = excluded.archived_at,
                deleted_at = excluded.deleted_at, version = excluded.version,
                record = excluded.record
            """, arguments: [project.id, StoreHome.marker, project.name, project.path,
                             project.gitRemote, project.gitDefaultBranch,
                             project.isGeneral ? 1 : 0, project.remoteAccess.rawValue,
                             project.createdAt, project.archivedAt, project.deletedAt,
                             project.version, record])
    }

    func putAttachment(_ attachment: TPAttachment, itemID: String?, localPath: String?) throws {
        try pool.write { db in
            let record = try ThreadRecords.encode(attachment)
            try db.execute(sql: """
                INSERT INTO attachments
                    (id, thread_id, item_id, kind, name, mime, size_bytes, sha256,
                     capture_id, local_path, created_at, record)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    thread_id = excluded.thread_id, item_id = excluded.item_id,
                    kind = excluded.kind, name = excluded.name, mime = excluded.mime,
                    size_bytes = excluded.size_bytes, sha256 = excluded.sha256,
                    capture_id = excluded.capture_id, local_path = excluded.local_path,
                    created_at = excluded.created_at, record = excluded.record
                """, arguments: [attachment.id, attachment.threadID, itemID,
                                 attachment.kind.rawValue, attachment.name, attachment.mime,
                                 attachment.sizeBytes, attachment.sha256, attachment.captureID,
                                 localPath, attachment.createdAt, record])
        }
    }

    func setNativeConsumption(_ value: NativeConsumption) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO native_consumption
                    (thread_id, item_id, spoken, resume_sentence, dismissed_from_pill, speak_reply)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [value.threadID, value.itemID, value.spoken,
                                 value.resumeSentence, value.dismissedFromPill, value.speakReply])
        }
    }

    // MARK: - reading

    func project(_ id: String) throws -> TPProject? {
        try pool.read { db in
            guard let record = try String.fetchOne(
                db, sql: "SELECT record FROM projects WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try ThreadRecords.decodeProject(record, homeID: self.homeID)
        }
    }

    func projects(includeArchived: Bool) throws -> [TPProject] {
        try pool.read { db in
            var sql = "SELECT record FROM projects"
            if !includeArchived {
                sql += " WHERE archived_at IS NULL AND deleted_at IS NULL"
            }
            sql += " ORDER BY name ASC, id ASC"
            return try String.fetchAll(db, sql: sql).map {
                try ThreadRecords.decodeProject($0, homeID: self.homeID)
            }
        }
    }

    func thread(_ id: String) throws -> TPThread? {
        try pool.read { db in
            guard let record = try String.fetchOne(
                db, sql: "SELECT record FROM threads WHERE id = ?", arguments: [id]) else {
                return nil
            }
            return try ThreadRecords.decodeThread(record, homeID: self.homeID)
        }
    }

    func threads(includeArchived: Bool) throws -> [TPThread] {
        try pool.read { db in
            try threads(in: db, includeArchived: includeArchived)
        }
    }

    private func threads(in db: Database, includeArchived: Bool) throws -> [TPThread] {
        var sql = "SELECT record FROM threads"
        if !includeArchived {
            sql += " WHERE archived_at IS NULL AND deleted_at IS NULL"
        }
        sql += " ORDER BY last_activity_at DESC, id DESC"
        return try String.fetchAll(db, sql: sql).map {
            try ThreadRecords.decodeThread($0, homeID: self.homeID)
        }
    }

    func open(threadID: String, sinceSeq: Int?) throws -> ThreadOpenPage {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT record, last_seq FROM threads WHERE id = ?",
                arguments: [threadID]) else {
                throw ThreadStoreError(code: .notFound, message: "no thread \(threadID)")
            }
            let record: String = row["record"]
            let lastSeq: Int = row["last_seq"]
            if let sinceSeq, sinceSeq > lastSeq {
                throw ThreadStoreError(
                    code: .snapshotRequired,
                    message: "sinceSeq \(sinceSeq) is above the thread's last number \(lastSeq)")
            }
            let thread = try ThreadRecords.decodeThread(record, homeID: self.homeID)

            let turnRows = try Row.fetchAll(
                db, sql: "SELECT record FROM turns WHERE thread_id = ? ORDER BY created_at DESC, id DESC",
                arguments: [threadID])
            let hasOlder = turnRows.count > 20
            let turns = try turnRows.prefix(20).map { turnRow -> TPTurn in
                let json: String = turnRow["record"]
                return try ThreadRecords.decodeTurn(json)
            }
            let items = try self.items(in: db, threadID: threadID, turnIDs: turns.map(\.id))
            var events: [StoredEvent] = []
            if let sinceSeq {
                events = try self.events(in: db, threadID: threadID, afterSeq: sinceSeq)
            }
            return ThreadOpenPage(thread: thread, lastSeq: lastSeq, turns: turns, items: items,
                                  events: events, hasOlder: hasOlder)
        }
    }

    func history(threadID: String, beforeTurnID: String, limit: Int) throws -> TPThreadHistoryResult {
        try pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT record FROM turns WHERE thread_id = ? ORDER BY created_at DESC, id DESC",
                arguments: [threadID])
            var ordered = try rows.map { row -> TPTurn in
                let json: String = row["record"]
                return try ThreadRecords.decodeTurn(json)
            }
            if let index = ordered.firstIndex(where: { $0.id == beforeTurnID }) {
                ordered = Array(ordered[(index + 1)...])
            }
            let hasOlder = ordered.count > limit
            let selected = Array(ordered.prefix(limit))
            let items = try self.items(in: db, threadID: threadID, turnIDs: selected.map(\.id))
            return TPThreadHistoryResult(hasOlder: hasOlder, items: items, turns: selected)
        }
    }

    func events(threadID: String, afterSeq: Int) throws -> [StoredEvent] {
        try pool.read { db in
            try events(in: db, threadID: threadID, afterSeq: afterSeq)
        }
    }

    private func events(in db: Database, threadID: String, afterSeq: Int) throws -> [StoredEvent] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT seq, origin, origin_seq, type, turn_id, item_id, payload, created_at
            FROM thread_events WHERE thread_id = ? AND seq > ? ORDER BY seq ASC
            """, arguments: [threadID, afterSeq])
        return try rows.map { row in
            let rawType: String = row["type"]
            guard let type = TPEventType(rawValue: rawType) else {
                throw ThreadStoreError(code: .invalidParams,
                                       message: "unknown stored event type \(rawType)")
            }
            let payloadJSON: String = row["payload"]
            let payload = try JSONDecoder().decode(TPDurableEvent.self,
                                                   from: Data(payloadJSON.utf8))
            return StoredEvent(threadID: threadID, seq: row["seq"],
                               origin: StoreHome.resolve(row["origin"], homeID: self.homeID),
                               originSeq: row["origin_seq"], type: type,
                               turnID: row["turn_id"], itemID: row["item_id"],
                               at: row["created_at"], payload: try self.resolve(payload))
        }
    }

    /// The stored payload's thread record carries the word `self`; the record
    /// this Mac reads carries its current home id.
    private func resolve(_ payload: TPDurableEvent) throws -> TPDurableEvent {
        guard let thread = payload.thread else { return payload }
        let json = try ThreadRecords.encode(thread)
        let resolved = try ThreadRecords.decodeThread(json, homeID: homeID)
        return TPDurableEvent(item: payload.item, thread: resolved, threadID: payload.threadID,
                              turn: payload.turn, type: payload.type)
    }

    func lastSeq(threadID: String) throws -> Int {
        try pool.read { db in
            guard let value = try Int.fetchOne(
                db, sql: "SELECT last_seq FROM threads WHERE id = ?", arguments: [threadID]) else {
                throw ThreadStoreError(code: .notFound, message: "no thread \(threadID)")
            }
            return value
        }
    }

    private func items(in db: Database, threadID: String, turnIDs: [String]) throws -> [TPItem] {
        guard !turnIDs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: turnIDs.count).joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT record FROM items
            WHERE thread_id = ? AND turn_id IN (\(placeholders))
            ORDER BY created_at ASC, id ASC
            """, arguments: StatementArguments([threadID] + turnIDs))
        return try rows.map { row in
            let json: String = row["record"]
            return try ThreadRecords.decodeItem(json)
        }
    }

    func attachments(threadID: String) throws -> [StoredAttachment] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT record, item_id, local_path FROM attachments
                WHERE thread_id = ? ORDER BY created_at ASC, id ASC
                """, arguments: [threadID])
            return try rows.map { row in
                let json: String = row["record"]
                let attachment = try JSONDecoder().decode(TPAttachment.self,
                                                          from: Data(json.utf8))
                return StoredAttachment(attachment: attachment, itemID: row["item_id"],
                                        localPath: row["local_path"])
            }
        }
    }

    func nativeConsumption(threadID: String, itemID: String) throws -> NativeConsumption? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT spoken, resume_sentence, dismissed_from_pill, speak_reply
                FROM native_consumption WHERE thread_id = ? AND item_id = ?
                """, arguments: [threadID, itemID]) else {
                return nil
            }
            return NativeConsumption(threadID: threadID, itemID: itemID, spoken: row["spoken"],
                                     resumeSentence: row["resume_sentence"],
                                     dismissedFromPill: row["dismissed_from_pill"],
                                     speakReply: row["speak_reply"])
        }
    }

    // MARK: - observation

    /// GRDB's value observation: once with what is there, and again after every
    /// write that changes the answer. The caller names the queue, because a
    /// command-line test has no main run loop.
    func observeThreads(includeArchived: Bool, on queue: DispatchQueue = .main,
                        onChange: @escaping ([TPThread]) -> Void) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db in
            try self.threads(in: db, includeArchived: includeArchived)
        }
        return observation.start(in: pool, scheduling: .async(onQueue: queue),
                                 onError: { _ in }, onChange: onChange)
    }

    // MARK: - attention

    /// True only when the contract's own fields say the person is needed: the
    /// activity is `waiting`, the last turn failed or was interrupted, or
    /// activity is later than the last read (or it was never read).
    static func needsAttention(_ thread: TPThread) -> Bool {
        if thread.activity == .waiting { return true }
        if let lastTurn = thread.lastTurn,
           lastTurn.status == .failed || lastTurn.status == .interrupted {
            return true
        }
        guard let lastReadAt = thread.lastReadAt else { return true }
        return thread.lastActivityAt > lastReadAt
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: now())
    }
}

extension ThreadWrite {
    var threadID: String {
        switch self {
        case .thread(let thread): return thread.id
        case .turn(let turn): return turn.threadID
        case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
            return item.threadID
        }
    }

    var isThread: Bool {
        if case .thread = self { return true }
        return false
    }

    var eventType: TPEventType {
        switch self {
        case .thread: return .threadUpdated
        case .turn: return .turnUpdated
        case .itemStarted: return .itemStarted
        case .itemUpdated: return .itemUpdated
        case .itemCompleted: return .itemCompleted
        }
    }

    var turnID: String? {
        switch self {
        case .thread: return nil
        case .turn(let turn): return turn.id
        case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
            return item.turnID
        }
    }

    var itemID: String? {
        switch self {
        case .thread, .turn: return nil
        case .itemStarted(let item), .itemUpdated(let item), .itemCompleted(let item):
            return item.id
        }
    }

    var payload: TPDurableEvent {
        switch self {
        case .thread(let thread):
            return TPDurableEvent(item: nil, thread: thread, threadID: thread.id, turn: nil,
                                  type: .threadUpdated)
        case .turn(let turn):
            return TPDurableEvent(item: nil, thread: nil, threadID: turn.threadID, turn: turn,
                                  type: .turnUpdated)
        case .itemStarted(let item):
            return TPDurableEvent(item: item, thread: nil, threadID: item.threadID, turn: nil,
                                  type: .itemStarted)
        case .itemUpdated(let item):
            return TPDurableEvent(item: item, thread: nil, threadID: item.threadID, turn: nil,
                                  type: .itemUpdated)
        case .itemCompleted(let item):
            return TPDurableEvent(item: item, thread: nil, threadID: item.threadID, turn: nil,
                                  type: .itemCompleted)
        }
    }
}
