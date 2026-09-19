import Foundation
import GRDB

// V1, task 1 — the schema, the records as the contract writes them, the `self`
// rule for the home id, attachments, native listening state, and "needs
// attention" computed from the contract's fields and nothing else (06 §3.2).
//
// Everything here goes through ThreadStore's public surface. No test reaches
// into a private function, and no test asserts against a double: the sink and
// the git probe used by the other suites are not used here at all.

let root = makeConfigRoot("v1-records")
defer { try? fixtureFileManager.removeItem(at: root) }

let (pool, store) = try openStore(configRoot: root, homeID: "h_mac_one")

// ---------------------------------------------------------------- the schema

// The store's steps are registered with K8's one migrator, so opening the file
// applies them, and applying them a second time changes nothing.
let applied = try pool.read { db in try StoreMigrations.migrator().appliedIdentifiers(db) }
require(applied.contains(ThreadStoreSchema.migrationID),
        "the thread store's migration \(ThreadStoreSchema.migrationID) is registered with K8's migrator")
require(applied.contains("0001 store meta"),
        "K8's own step is still there and was not renamed")
try StoreMigrations.migrator().migrate(pool)
let twice = try pool.read { db in try StoreMigrations.migrator().appliedIdentifiers(db) }
require(twice == applied, "migrating twice applies nothing twice")
ok("the migration is registered once and is idempotent")

let expectedTables = [
    "projects", "threads", "turns", "items", "items_fts", "thread_events",
    "attachments", "thread_commands", "native_consumption", "store_meta",
]
try pool.read { db in
    for table in expectedTables {
        require(try db.tableExists(table), "the table \(table) exists")
    }
}
ok("every table 06 §3.2 names exists")

// The log's two keys: one row per (thread, seq), and one per (thread, origin,
// origin_seq). Without the second, an adopted event could land twice.
try store.upsertProject(makeProject(id: "p_keys", name: "Keys", path: root.path))
_ = try store.apply([.thread(makeThread(id: "t_keys", projectID: "p_keys"))])
var duplicatedSeq = false
do {
    try pool.write { db in
        try db.execute(sql: """
            INSERT INTO thread_events (thread_id, seq, origin, origin_seq, type, payload, created_at)
            VALUES ('t_keys', 1, 'other', 9, 'thread.updated', '{}', '2026-09-19T10:00:00Z')
            """)
    }
    duplicatedSeq = true
} catch { }
require(!duplicatedSeq, "a second row with the same (thread_id, seq) is refused by the primary key")

var duplicatedOrigin = false
do {
    try pool.write { db in
        try db.execute(sql: """
            INSERT INTO thread_events (thread_id, seq, origin, origin_seq, type, payload, created_at)
            VALUES ('t_keys', 900, 'self', 1, 'thread.updated', '{}', '2026-09-19T10:00:00Z')
            """)
    }
    duplicatedOrigin = true
} catch { }
require(!duplicatedOrigin,
        "a second row with the same (thread_id, origin, origin_seq) is refused by the unique index")
ok("thread_events keeps one row per (thread_id, seq) and one per (thread_id, origin, origin_seq)")

// ------------------------------------------------- records stored as written

let projectPath = makeFolder(root.appendingPathComponent("work", isDirectory: true)).path
let project = makeProject(
    id: "p_one", name: "Atika", path: projectPath,
    gitRemote: "git@github.com:safet/atika.git", gitDefaultBranch: "main",
    remoteAccess: .readOnly, version: 4)
try store.upsertProject(project)
let readProject = try store.project("p_one")
require(readProject?.id == "p_one", "the project is found by its id")
require(readProject?.gitRemote == project.gitRemote, "gitRemote is kept as it was written")
require(readProject?.gitDefaultBranch == "main", "gitDefaultBranch is kept as it was written")
require(readProject?.remoteAccess == .readOnly, "remoteAccess keeps the contract's spelling")
require(readProject?.version == 4, "the record's version is kept")

let workspace = TPWorkspaceRoot(
    baseCommit: "abc1234", branch: "atika/a-thread-aabbcc", kind: .worktree,
    path: "\(root.path)/worktrees/p_one/t_one", rootID: "t_one")
let thread = makeThread(
    id: "t_one", projectID: "p_one", title: "Fix the store", workspaceRoot: workspace,
    branch: "atika/a-thread-aabbcc", version: 7)
_ = try store.apply([.thread(thread)])
let readThread = try store.thread("t_one")
require(readThread != nil, "the thread is found by its id")
require(readThread?.workspaceRoot == workspace, "workspaceRoot is stored as written, with its branch and base commit")
require(readThread?.branch == "atika/a-thread-aabbcc", "the thread's branch name is kept")
require(readThread?.supports == thread.supports, "the abilities list is kept")
require(readThread?.titleSource == .auto, "titleSource is kept")
require(readThread?.trustProfile == .workspace, "the trust profile is kept")
require(readThread?.version == 7, "the thread's version is kept")

let git = TPTurnGit(branch: "main", dirty: true, headCommit: "def5678",
                    pushed: false, unpushedCount: 2, upstreamRef: "origin/main")
let checkpoints = TPTurnCheckpoints(after: "refs/atika/checkpoints/t_one/after",
                                    before: "refs/atika/checkpoints/t_one/before")
let changed = [TPChangedFile(added: 12, path: "swift/Threads/Store/ThreadStore.swift", removed: 3)]
let turn = makeTurn(id: "turn_one", threadID: "t_one", status: .interrupted,
                    git: git, checkpoints: checkpoints, changedFiles: changed,
                    stopReason: .cancelled)
_ = try store.apply([.turn(turn)])
let openedForTurn = try store.open(threadID: "t_one", sinceSeq: nil)
let storedTurn = openedForTurn.turns.first { $0.id == "turn_one" }
require(storedTurn?.status == .interrupted, "the interrupted status is stored")
require(storedTurn?.git == git, "the turn's git state is stored as written")
require(storedTurn?.checkpoints == checkpoints, "the turn's checkpoint references are stored as written")
require(storedTurn?.changedFiles == changed, "the turn's changed files are stored as written")
require(storedTurn?.stopReason == .cancelled, "the stop reason is stored")
require(storedTurn?.startedBy.kind == .user, "startedBy is stored")
require(storedTurn?.ranOn.label == "Mac mini", "ranOn says which Mac ran the turn")
ok("Project, Thread and Turn are stored exactly as the contract writes them")

// ------------------------------------------------------ the queried columns

// Each table keeps the whole record as JSON plus the few fields that are
// queried, as columns. The columns must agree with the record, or a listing
// would answer something the record denies.
try pool.read { db in
    let row = try Row.fetchOne(db, sql: """
        SELECT activity, project_id, last_activity_at FROM threads WHERE id = 't_one'
        """)
    require(row != nil, "the thread has a row of its own")
    let activityColumn: String = row!["activity"]
    let projectColumn: String = row!["project_id"]
    let lastActivityColumn: String = row!["last_activity_at"]
    require(activityColumn == thread.activity.rawValue, "the activity column equals the record's activity")
    require(projectColumn == "p_one", "the project column equals the record's projectId")
    require(lastActivityColumn == thread.lastActivityAt, "the lastActivityAt column equals the record's")
}
ok("the queried columns agree with the record they were taken from")

// ------------------------------------------------------------ the self rule

// 06 §3.2: the store never writes the home's id into a row or a payload. It
// writes the word `self`, and the exits put the current id in its place. A home
// id that arrives only at sign-in therefore re-keys nothing.
let onDisk: String = try pool.read { db in
    try String.fetchOne(db, sql: "SELECT home_id FROM threads WHERE id = 't_one'") ?? ""
}
require(onDisk == StoreHome.marker, "the thread row carries the word \(StoreHome.marker), not a home id")
require(StoreHome.marker == "self", "the marker is the word self")
let payloadHomes: [String] = try pool.read { db in
    try String.fetchAll(db, sql: "SELECT payload FROM thread_events WHERE thread_id = 't_one'")
}
require(!payloadHomes.isEmpty, "there are payloads to look at")
require(payloadHomes.allSatisfy { !$0.contains("h_mac_one") },
        "no stored payload carries the home's id")

require(readThread?.homeID == "h_mac_one", "a read through the store puts the current home id in place")
let otherStore = ThreadStore(pool: pool, paths: makePaths(root), homeID: { "h_mac_two" })
require(try otherStore.thread("t_one")?.homeID == "h_mac_two",
        "the same rows read under another home id answer with that id")
require(try otherStore.project("p_one")?.homeID == "h_mac_two",
        "the rule holds for projects as well as threads")
ok("the home id is the word self on disk and the current id at the exits")

// Before sign-in the store has no home id and uses a locally generated
// installation id kept in store_meta; it is stable across reads.
let installation = try pool.write { db in try StoreHome.installationID(db) }
require(!installation.isEmpty, "an installation id exists before sign-in")
require(installation != StoreHome.marker, "the installation id is not the marker itself")
let installationAgain = try pool.write { db in try StoreHome.installationID(db) }
require(installationAgain == installation, "the installation id is minted once and then reused")
ok("the installation id lives in store_meta and is stable")

// --------------------------------------------------------------- attachments

let picture = makeAttachment(
    id: "att_one", threadID: "t_one", marks: [makeMark(n: 1), makeMark(n: 2, note: nil, underText: nil)],
    context: makeContext(), modelText: "a rectangle around the total",
    captureID: "cap_2026_09_19_1")
let localPath = "\(root.path)/captures/2026-09-19/shot.png"
try store.putAttachment(picture, itemID: "item_one", localPath: localPath)

let listed = try store.attachments(threadID: "t_one")
require(listed.count == 1, "the thread has one attachment")
require(listed[0].attachment == picture,
        "marks, context and modelText come back exactly as they were given")
require(listed[0].itemID == "item_one", "the listing carries the item id S4 relinks by")
require(listed[0].localPath == localPath, "the listing carries the local path of the file in place")
require(listed[0].attachment.captureID == "cap_2026_09_19_1",
        "an attachment with a captureId points at the captured file in place")

// The marks must survive as written, not as something re-encoded by a second
// vocabulary: the note text and the screen text under the mark are branch 07's.
require(listed[0].attachment.marks?.first?.note == "look here", "a mark's note is untouched")
require(listed[0].attachment.marks?.first?.underText == "Total: 42",
        "the screen text under a mark is untouched")
require(listed[0].attachment.marks?.count == 2, "both marks are kept, in order")
require(listed[0].attachment.marks?[1].n == 2, "the marks keep their order numbers")
ok("attachments keep marks, context and modelText untouched and carry the item id and local path")

// ------------------------------------------------- native listening state

let consumption = NativeConsumption(
    threadID: "t_one", itemID: "item_one", spoken: true,
    resumeSentence: "Carry on with the store", dismissedFromPill: false, speakReply: true)
try store.setNativeConsumption(consumption)
require(try store.nativeConsumption(threadID: "t_one", itemID: "item_one") == consumption,
        "the pill's listening state round-trips")
try store.setNativeConsumption(NativeConsumption(
    threadID: "t_one", itemID: "item_one", spoken: true, resumeSentence: nil,
    dismissedFromPill: true, speakReply: false))
require(try store.nativeConsumption(threadID: "t_one", itemID: "item_one")?.dismissedFromPill == true,
        "writing it again replaces the row rather than adding a second one")
require(try store.nativeConsumption(threadID: "t_one", itemID: "nothing") == nil,
        "an item with no listening state answers nothing")
ok("native_consumption is Mac-only state that round-trips and replaces in place")

// ---------------------------------------------------- needs attention

// 06 §3.2: computed from the contract's fields and nothing else. There is no
// separate Mac state word.
let quiet = makeThread(id: "t_quiet", projectID: "p_one",
                       lastActivityAt: "2026-09-19T10:00:00Z", lastReadAt: "2026-09-19T10:00:00Z")
require(!ThreadStore.needsAttention(quiet), "an idle, read, successful thread does not need the person")

let waiting = makeThread(
    id: "t_wait", projectID: "p_one", activity: .waiting,
    attention: TPThreadAttention(itemID: "i_1", kind: .approval, summary: "Run `rm -rf build`?"),
    lastActivityAt: "2026-09-19T10:00:00Z", lastReadAt: "2026-09-19T10:00:00Z")
require(ThreadStore.needsAttention(waiting), "a thread waiting on an approval needs the person")

for status in [TPTurnStatus.failed, TPTurnStatus.interrupted] {
    let broken = makeThread(
        id: "t_\(status.rawValue)", projectID: "p_one",
        lastTurn: TPThreadLastTurn(endedAt: fixtureNow, ranOn: makeRanOn(), status: status, turnID: "x"),
        lastActivityAt: "2026-09-19T10:00:00Z", lastReadAt: "2026-09-19T10:00:00Z")
    require(ThreadStore.needsAttention(broken), "a thread whose last turn is \(status.rawValue) needs the person")
}
for status in [TPTurnStatus.completed, TPTurnStatus.running, TPTurnStatus.queued] {
    let fine = makeThread(
        id: "t_ok_\(status.rawValue)", projectID: "p_one",
        lastTurn: TPThreadLastTurn(endedAt: fixtureNow, ranOn: makeRanOn(), status: status, turnID: "x"),
        lastActivityAt: "2026-09-19T10:00:00Z", lastReadAt: "2026-09-19T10:00:00Z")
    require(!ThreadStore.needsAttention(fine), "a thread whose last turn is \(status.rawValue) does not")
}

let unread = makeThread(id: "t_unread", projectID: "p_one",
                        lastActivityAt: "2026-09-19T11:00:00Z", lastReadAt: "2026-09-19T10:00:00Z")
require(ThreadStore.needsAttention(unread), "activity later than the last read needs the person")
let neverRead = makeThread(id: "t_never", projectID: "p_one",
                           lastActivityAt: "2026-09-19T11:00:00Z", lastReadAt: nil)
require(ThreadStore.needsAttention(neverRead), "a thread that was never read needs the person")
let running = makeThread(id: "t_run", projectID: "p_one", activity: .running,
                         lastActivityAt: "2026-09-19T10:00:00Z", lastReadAt: "2026-09-19T10:00:00Z")
require(!ThreadStore.needsAttention(running), "a running thread on its own does not need the person")
ok("needs attention is computed from activity, attention, the last turn's status and the read time")

// ------------------------------------------------------------- the listings

try store.upsertProject(makeProject(id: "p_gone", name: "Old", path: projectPath,
                                    archivedAt: "2026-09-18T09:00:00Z"))
require(try store.projects(includeArchived: false).map(\.id).sorted() == ["p_keys", "p_one"],
        "an archived project is left out unless it is asked for")
require(try store.projects(includeArchived: true).map(\.id).contains("p_gone"),
        "an archived project is listed when it is asked for")

_ = try store.apply([.thread(makeThread(id: "t_arch", projectID: "p_one",
                                        archivedAt: "2026-09-18T09:00:00Z"))])
let visibleThreads = try store.threads(includeArchived: false).map(\.id)
let allThreads = try store.threads(includeArchived: true).map(\.id)
require(!visibleThreads.contains("t_arch"),
        "an archived thread is hidden by default; archive only hides and is reversible")
require(allThreads.contains("t_arch"), "an archived thread is still there")
ok("the listings hide archived records by default and keep them")

// --------------------------------------------- native readers do not poll

// 06 §3.2: the pill, the menu bar and the hotkey slots observe the store and
// are told when a row they care about changes, instead of re-reading
// everything on every refresh.
let observed = DispatchSemaphore(value: 0)
let box = ObservationBox()
let observationQueue = DispatchQueue(label: "v1-records-observation")
let watching = store.observeThreads(includeArchived: false, on: observationQueue) { threads in
    box.record(threads)
    observed.signal()
}
require(observed.wait(timeout: .now() + 10) == .success,
        "the observation delivers what is there now, without anything being written")
let firstDelivery = box.count

_ = try store.apply([.thread(makeThread(id: "t_watched", projectID: "p_one", title: "Watched"))])
require(observed.wait(timeout: .now() + 10) == .success,
        "writing a thread tells the reader; nothing had to ask again")
require(box.count > firstDelivery, "a second value really arrived")
require(box.latest.contains { $0.id == "t_watched" }, "the value carries the new thread")
watching.cancel()
ok("native readers are told when a thread changes")

print("thread store records: schema, records, the self rule, attachments and attention")
