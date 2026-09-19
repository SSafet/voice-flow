import Foundation

// ─────────────────────────────────────────────────────────────────────────
// The fakes and factories every replication suite drives the module with.
//
// The replication module talks to the outside world through five seams:
// `ReplicationChannel` (work package L3's outbox, live frame, downward intake
// and command intake), `ReplicationStore` (work package V1's thread store and
// its persona records), `ReplicationEngine` (work package V5's turn engine
// method table), `BranchFetcher` (work package V4's git runner) and
// `HomeRuntimes` / `RouteReport` (work package V3's launcher and V7's route
// report). The tests substitute all of them, so a suite neither binds a port
// nor starts a model nor runs git; the module's behaviour is what is observed.
// ─────────────────────────────────────────────────────────────────────────

func replicationExpect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

// ─────────────────────────── time ───────────────────────────

enum ReplicationTestClock {
    static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }

    static let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    static func at(_ seconds: Double) -> String { string(epoch.addingTimeInterval(seconds)) }
}

// ─────────────────────────── factories ───────────────────────────

enum ReplicationFixtures {
    static func thread(
        id: String = "t1",
        projectID: String = "p1",
        homeID: String = "self",
        title: String = "Fix the cart",
        activity: TPThreadActivity = .idle,
        cloud: TPThreadCloud? = nil,
        branch: String? = nil,
        mirrorBlocked: TPMirrorBlocked? = nil,
        version: Int = 1
    ) -> TPThread {
        TPThread(
            activity: activity,
            archivedAt: nil,
            attention: nil,
            branch: branch,
            cloud: cloud,
            createdAt: "2026-09-19T10:00:00.000Z",
            deletedAt: nil,
            externalClient: nil,
            homeID: homeID,
            id: id,
            lastActivityAt: "2026-09-19T10:00:00.000Z",
            lastReadAt: nil,
            lastTurn: nil,
            mirrorBlocked: mirrorBlocked,
            model: nil,
            personaID: nil,
            personaName: nil,
            pinnedAt: nil,
            pinnedSlot: nil,
            projectID: projectID,
            reasoningEffort: nil,
            runtime: .opencode,
            startedBy: nil,
            supports: [],
            title: title,
            titleSource: .auto,
            trustProfile: nil,
            version: version,
            workspaceRoot: TPWorkspaceRoot(
                baseCommit: nil,
                branch: nil,
                kind: .project,
                path: "/tmp/project",
                rootID: projectID
            )
        )
    }

    static func project(
        id: String = "p1",
        homeID: String = "self",
        name: String = "pantria",
        version: Int = 1
    ) -> TPProject {
        TPProject(
            archivedAt: nil,
            available: true,
            createdAt: "2026-09-19T10:00:00.000Z",
            deletedAt: nil,
            gitDefaultBranch: "main",
            gitRemote: "git@github.com:SSafet/pantria.git",
            homeID: homeID,
            id: id,
            isGeneral: false,
            name: name,
            path: "/tmp/pantria",
            remoteAccess: .readWrite,
            version: version
        )
    }

    static func persona(
        id: String = "flora",
        homeID: String = "self",
        version: Int = 1
    ) -> TPPersona {
        TPPersona(
            coreMemory: "remember the cart",
            delegates: [],
            deletedAt: nil,
            description: "the assistant",
            homeID: homeID,
            id: id,
            instructions: "Be brief.",
            isDefault: true,
            issues: [],
            model: nil,
            name: "FLORA",
            reasoningEffort: nil,
            revision: "rev-1",
            skills: [],
            usable: true,
            version: version,
            voice: nil
        )
    }

    static func cloud(model: String = "gpt-5.6-pro") -> TPThreadCloud {
        TPThreadCloud(
            baseCommit: "abc123",
            baseRef: "refs/remotes/origin/main",
            headCommit: nil,
            model: model,
            pushed: false
        )
    }

    static func item(
        id: String = "i1",
        threadID: String = "t1",
        turnID: String = "turn1",
        kind: TPItemKind = .assistantMessage,
        text: String? = "hello",
        notice: TPNotice? = nil,
        status: TPItemStatus = .completed
    ) -> TPItem {
        TPItem(
            agentName: nil,
            approval: nil,
            attachments: nil,
            commandID: nil,
            completedAt: "2026-09-19T10:00:01.000Z",
            context: nil,
            createdAt: "2026-09-19T10:00:00.000Z",
            fullTextAttachmentID: nil,
            id: id,
            kind: kind,
            notice: notice,
            parentItemID: nil,
            plan: nil,
            question: nil,
            sentFrom: nil,
            status: status,
            text: text,
            threadID: threadID,
            toolCall: nil,
            truncated: nil,
            turnID: turnID
        )
    }

    /// One durable event of this Mac's own log, as work package V1 hands it to
    /// the replication sink: both numbers and the record it carries.
    static func ownEvent(
        threadID: String = "t1",
        origin: String = "self",
        originSeq: Int,
        seq: Int? = nil,
        at: String? = nil,
        event: TPDurableEvent? = nil
    ) -> ReplicatedEvent {
        ReplicatedEvent(
            threadID: threadID,
            seq: seq ?? originSeq,
            origin: origin,
            originSeq: originSeq,
            at: at ?? ReplicationTestClock.at(Double(originSeq)),
            event: event ?? TPDurableEvent(
                item: nil,
                thread: thread(id: threadID),
                threadID: threadID,
                turn: nil,
                type: .threadUpdated
            )
        )
    }

    /// A downward adopt item, as work package L3 hands it from Atika.
    static func down(
        threadID: String = "t1",
        origin: String = "atika",
        originSeq: Int,
        at: String? = nil,
        event: TPDurableEvent
    ) -> TPThreadEventDown {
        TPThreadEventDown(
            at: at ?? ReplicationTestClock.at(Double(originSeq)),
            event: event,
            origin: origin,
            originSeq: originSeq
        )
    }

    static func downItemEvent(
        threadID: String = "t1",
        itemID: String = "cloud-i1",
        text: String = "from the cloud"
    ) -> TPDurableEvent {
        TPDurableEvent(
            item: item(id: itemID, threadID: threadID, text: text),
            thread: nil,
            threadID: threadID,
            turn: nil,
            type: .itemCompleted
        )
    }

    static func homeDescribe(
        label: String = "Safet's MacBook Pro",
        runtimes: [TPHomeRuntime] = [
            TPHomeRuntime(
                available: true,
                detail: nil,
                kind: .opencode,
                version: "1.17.11"
            )
        ]
    ) -> TPHomeDescribe {
        TPHomeDescribe(label: label, runtimes: runtimes)
    }
}

// ─────────────────────────── the channel ───────────────────────────

/// One call the module made to L3's outbox. A log stream passes `seq` and no
/// body; a state stream passes a body and lets the outbox number it.
struct RecordedAppend: Equatable {
    let stream: String
    let kind: String
    let bodyJson: String?
    let seq: Int?
}

struct RecordedLive: Equatable {
    let stream: String
    let kind: String
    let bodyJson: String
}

final class FakeChannel: ReplicationChannel, @unchecked Sendable {
    private(set) var appends: [RecordedAppend] = []
    private(set) var liveSent: [RecordedLive] = []
    private(set) var registeredLogPrefixes: [String] = []
    private(set) var registeredStatePrefixes: [String] = []
    private(set) var registeredDownwardPrefixes: [String] = []
    private(set) var registeredCommandKinds: [String] = []

    private var logReaders: [String: ReplicationLogReader] = [:]
    private var stateRebuilders: [String: ReplicationStateRebuilder] = [:]
    private var downwardHandlers: [String: ReplicationDownwardHandler] = [:]
    private var commandHandlers: [String: ReplicationCommandHandler] = [:]
    private var blockedHandlers: [(StreamBlock) -> Void] = []

    /// A test sets this to make the outbox refuse one append, the way a
    /// constraint failure inside the storing transaction would.
    var failAppend: ((RecordedAppend) throws -> Void)?

    func append(stream: String, kind: String, bodyJson: String?, seq: Int?) throws {
        let call = RecordedAppend(stream: stream, kind: kind, bodyJson: bodyJson, seq: seq)
        try failAppend?(call)
        appends.append(call)
    }

    func registerLog(prefix: String, reader: @escaping ReplicationLogReader) {
        registeredLogPrefixes.append(prefix)
        logReaders[prefix] = reader
    }

    func registerState(prefix: String, rebuild: @escaping ReplicationStateRebuilder) {
        registeredStatePrefixes.append(prefix)
        stateRebuilders[prefix] = rebuild
    }

    func registerDownward(prefix: String, handler: @escaping ReplicationDownwardHandler) {
        registeredDownwardPrefixes.append(prefix)
        downwardHandlers[prefix] = handler
    }

    func registerCommand(kind: String, handler: @escaping ReplicationCommandHandler) {
        registeredCommandKinds.append(kind)
        commandHandlers[kind] = handler
    }

    func send(stream: String, kind: String, bodyJson: String) {
        liveSent.append(RecordedLive(stream: stream, kind: kind, bodyJson: bodyJson))
    }

    func onBlocked(_ handler: @escaping (StreamBlock) -> Void) {
        blockedHandlers.append(handler)
    }

    // ── the suite's side of the fake ────────────────────────────────────

    func readLog(_ stream: String, afterSeq: Int, maxBytes: Int = 256 * 1024) throws -> [ReplicationItem] {
        guard let reader = logReaders[prefix(of: stream)] else {
            throw FakeChannelError.noReader(stream)
        }
        return try reader(stream, afterSeq, maxBytes)
    }

    func rebuildState(_ prefix: String) throws -> [ReplicationItem] {
        guard let rebuild = stateRebuilders[prefix] else {
            throw FakeChannelError.noReader(prefix)
        }
        return try rebuild()
    }

    func deliver(_ stream: String, kind: String, bodyJson: String, seq: Int) throws {
        guard let handler = downwardHandlers[prefix(of: stream)] else {
            throw FakeChannelError.noReader(stream)
        }
        try handler(stream, ReplicationItem(seq: seq, kind: kind, bodyJson: bodyJson, sum: "sum-\(seq)"))
    }

    func deliverCommand(_ command: ReplicationCommand) async -> CommandOutcome {
        guard let handler = commandHandlers[command.kind] else {
            return .rejected(code: "invalid", message: "no handler for \(command.kind)")
        }
        return await handler(command)
    }

    func raise(_ block: StreamBlock) {
        for handler in blockedHandlers { handler(block) }
    }

    private func prefix(of stream: String) -> String {
        let colon = stream.firstIndex(of: ":")
        return colon.map { String(stream[stream.startIndex..<$0]) } ?? stream
    }
}

enum FakeChannelError: Error, Equatable {
    case noReader(String)
    case appendRefused(String)
}

// ─────────────────────────── the store ───────────────────────────

final class FakeStore: ReplicationStore, @unchecked Sendable {
    var events: [String: [ReplicatedEvent]] = [:]
    var threadsByID: [String: TPThread] = [:]
    var projectList: [TPProject] = []
    var personaList: [TPPersona] = []
    var commandResults: [String: String] = [:]
    var mirrorBlocks: [String: TPMirrorBlocked?] = [:]
    var movedOwnEvents: [(threadID: String, above: Int, toOrigin: String)] = []
    var notices: [ReplicatedEvent] = []
    var mergedClouds: [(threadID: String, cloud: TPThreadCloud?, branch: String?)] = []

    /// Work package V1 fires its `ThreadEventSink` inside the storing
    /// transaction; the suite wires the same call here.
    var sink: (([ReplicatedEvent]) throws -> Void)?

    func seedThread(_ thread: TPThread) { threadsByID[thread.id] = thread }

    func seedOwn(_ event: ReplicatedEvent) {
        events[event.threadID, default: []].append(event)
    }

    func ownEvents(threadID: String, afterOriginSeq: Int) throws -> [ReplicatedEvent] {
        (events[threadID] ?? [])
            .filter { $0.origin == "self" && $0.originSeq > afterOriginSeq }
            .sorted { $0.originSeq < $1.originSeq }
    }

    func highestOwnOriginSeq(threadID: String) throws -> Int {
        (events[threadID] ?? [])
            .filter { $0.origin != "atika" }
            .map(\.originSeq)
            .max() ?? 0
    }

    func thread(_ id: String) throws -> TPThread? { threadsByID[id] }

    func projects() throws -> [TPProject] { projectList }

    func personas() throws -> [TPPersona] { personaList }

    func adopt(_ down: TPThreadEventDown) throws -> ReplicatedEvent? {
        let existing = events[down.event.threadID] ?? []
        if existing.contains(where: { $0.origin == down.origin && $0.originSeq == down.originSeq }) {
            return nil
        }
        let nextSeq = (existing.map(\.seq).max() ?? 0) + 1
        let stored = ReplicatedEvent(
            threadID: down.event.threadID,
            seq: nextSeq,
            origin: down.origin,
            originSeq: down.originSeq,
            at: down.at,
            event: down.event
        )
        events[down.event.threadID, default: []].append(stored)
        if let thread = down.event.thread {
            threadsByID[thread.id] = thread
        }
        return stored
    }

    func mergeCloud(threadID: String, cloud: TPThreadCloud?, branch: String?) throws {
        mergedClouds.append((threadID, cloud, branch))
        guard var thread = threadsByID[threadID] else { return }
        thread = ReplicationFixtures.thread(
            id: thread.id,
            projectID: thread.projectID,
            homeID: thread.homeID,
            title: thread.title,
            activity: thread.activity,
            cloud: cloud ?? thread.cloud,
            branch: branch ?? thread.branch,
            mirrorBlocked: thread.mirrorBlocked,
            version: thread.version + 1
        )
        threadsByID[threadID] = thread
    }

    func setMirrorBlocked(threadID: String, blocked: TPMirrorBlocked?) throws {
        mirrorBlocks[threadID] = blocked
    }

    func restoreHave(threadID: String) throws -> [TPRestoreHave] {
        let origins = Set((events[threadID] ?? []).map(\.origin))
        return origins.sorted().map { origin in
            let last = (events[threadID] ?? [])
                .filter { $0.origin == origin }
                .map(\.originSeq)
                .max() ?? 0
            return TPRestoreHave(lastOriginSeq: last, origin: origin)
        }
    }

    func moveOwnEvents(threadID: String, above: Int, toOrigin: String) throws -> Int {
        movedOwnEvents.append((threadID, above, toOrigin))
        let moved = events[threadID] ?? []
        return moved.filter { $0.origin == "self" && $0.originSeq > above }.count
    }

    func commandResult(commandID: String) throws -> String? { commandResults[commandID] }

    func storeCommandResult(commandID: String, threadID: String?, method: String, resultJson: String) throws {
        commandResults[commandID] = resultJson
    }

    func appendNotice(threadID: String, code: TPNoticeCode, message: String,
                      git: TPNoticeGit?) throws -> ReplicatedEvent {
        let notice = TPNotice(code: code, git: git, message: message)
        let event = TPDurableEvent(
            item: ReplicationFixtures.item(
                id: "notice-\(notices.count + 1)",
                threadID: threadID,
                kind: .notice,
                text: nil,
                notice: notice
            ),
            thread: nil,
            threadID: threadID,
            turn: nil,
            type: .itemCompleted
        )
        let stored = ReplicatedEvent(
            threadID: threadID,
            seq: (events[threadID]?.map(\.seq).max() ?? 0) + 1,
            origin: "self",
            originSeq: (events[threadID]?.filter { $0.origin == "self" }.map(\.originSeq).max() ?? 0) + 1,
            at: ReplicationTestClock.at(100),
            event: event
        )
        events[threadID, default: []].append(stored)
        notices.append(stored)
        try sink?([stored])
        return stored
    }
}

// ─────────────────────────── the engine, git and the rest ───────────────

final class FakeEngine: ReplicationEngine, @unchecked Sendable {
    struct Call: Equatable { let method: String; let paramsJson: String; let commandID: String }
    private(set) var calls: [Call] = []
    var result: String = "{\"ok\":true}"
    var error: Error?

    func execute(method: String, paramsJson: String, commandID: String) throws -> String {
        calls.append(Call(method: method, paramsJson: paramsJson, commandID: commandID))
        if let error { throw error }
        return result
    }
}

final class FakeFetcher: BranchFetcher, @unchecked Sendable {
    private(set) var fetches: [(path: String, branch: String)] = []
    var result = BranchFetchResult(headCommit: "deadbeef", error: nil)

    func fetch(projectPath: String, branch: String) throws -> BranchFetchResult {
        fetches.append((projectPath, branch))
        return result
    }
}

final class FakeRuntimes: HomeRuntimes, @unchecked Sendable {
    var describe_: TPHomeDescribe = ReplicationFixtures.homeDescribe()
    func describe() -> TPHomeDescribe { describe_ }
}

final class FakeRouteReport: RouteReport, @unchecked Sendable {
    var watchedThreadID: String?
    func watchedLocally(threadID: String) -> Bool { watchedThreadID == threadID }
}

// ─────────────────────────── the module under test ──────────────────────

struct ReplicationTestWorld {
    let store = FakeStore()
    let channel = FakeChannel()
    let engine = FakeEngine()
    let fetcher = FakeFetcher()
    let runtimes = FakeRuntimes()
    let routeReport = FakeRouteReport()
    let replication: Replication

    init(homeID: String? = "home-1") {
        replication = Replication(deps: ReplicationDeps(
            store: store,
            channel: channel,
            engine: engine,
            fetcher: fetcher,
            runtimes: runtimes,
            routeReport: routeReport,
            homeID: { homeID },
            now: { ReplicationTestClock.epoch }
        ))
        store.sink = { [replication] events in try replication.stored(events) }
        try! replication.install()
    }

    func decode(_ item: ReplicationItem) -> TPThreadEventUp {
        try! JSONDecoder().decode(TPThreadEventUp.self, from: Data(item.bodyJson.utf8))
    }
}

func replicationDecode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
    try! JSONDecoder().decode(type, from: Data(json.utf8))
}
