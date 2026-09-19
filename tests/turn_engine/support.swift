import Foundation

// Shared doubles and builders for the turn-engine suites. This file is compiled
// into every `turn_*` suite beside the engine's own sources; it names the
// engine's public surface and nothing private.

var turnEngineFailures: [String] = []
var turnEngineChecks = 0

func check(_ what: String, _ condition: Bool, _ detail: String = "") {
    turnEngineChecks += 1
    if !condition {
        turnEngineFailures.append(detail.isEmpty ? what : "\(what): \(detail)")
    }
}

func checkEqual<T: Equatable>(_ what: String, _ got: T, _ expected: T) {
    check(what, got == expected, "\(got) is not \(expected)")
}

func expectError(_ what: String, _ body: () throws -> Void,
                 code: String, file: StaticString = #file, line: UInt = #line) {
    turnEngineChecks += 1
    do {
        try body()
        turnEngineFailures.append("\(what): no error was thrown")
    } catch let error as TurnEngineError {
        if error.code != code {
            turnEngineFailures.append("\(what): error code \(error.code) is not \(code)")
        }
    } catch {
        turnEngineFailures.append("\(what): unexpected error \(error)")
    }
}

func finishTurnEngine(_ suite: String) -> Never {
    if turnEngineFailures.isEmpty {
        print("\(suite): \(turnEngineChecks) checks, all pass")
        exit(0)
    }
    for failure in turnEngineFailures {
        FileHandle.standardError.write(Data("not ok - \(failure)\n".utf8))
    }
    FileHandle.standardError.write(Data("\(suite): \(turnEngineFailures.count) of \(turnEngineChecks) checks fail\n".utf8))
    exit(1)
}

// ───────────────────────────── contract builders ─────────────────────────────

let turnEngineFixedDate: Date = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: "2026-09-19T10:00:00Z")!
}()

func iso(_ date: Date = turnEngineFixedDate) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func userStartedBy() -> TPStartedBy {
    TPStartedBy(kind: .user, occurrenceKey: nil, runID: nil, triggerID: nil, triggerName: nil)
}

func triggerStartedBy(id: String = "trg1") -> TPStartedBy {
    TPStartedBy(kind: .trigger, occurrenceKey: "2026-09-19T00:00:00Z", runID: "run1",
                triggerID: id, triggerName: "Morning")
}

func macRanOn() -> TPRanOn {
    TPRanOn(homeID: "self", kind: .mac, label: "This Mac")
}

func makeThread(id: String, projectID: String = "p1", runtime: TPRuntime = .opencode,
                activity: TPThreadActivity = .idle, startedBy: TPStartedBy? = nil) -> TPThread {
    TPThread(activity: activity, archivedAt: nil, attention: nil, branch: nil, cloud: nil,
             createdAt: iso(), deletedAt: nil, externalClient: nil, homeID: "self", id: id,
             lastActivityAt: iso(), lastReadAt: nil, lastTurn: nil, mirrorBlocked: nil,
             model: nil, personaID: nil, personaName: nil, pinnedAt: nil, pinnedSlot: nil,
             projectID: projectID, reasoningEffort: nil, runtime: runtime, startedBy: startedBy,
             supports: [], title: "Thread \(id)", titleSource: .auto, trustProfile: .workspace,
             version: 1,
             workspaceRoot: TPWorkspaceRoot(baseCommit: nil, branch: nil, kind: .project,
                                            path: "/tmp/\(projectID)", rootID: "root-\(projectID)"))
}

func makeTurn(id: String, threadID: String, status: TPTurnStatus, runtime: TPRuntime = .opencode,
              startedBy: TPStartedBy? = nil, createdAt: Date = turnEngineFixedDate) -> TPTurn {
    TPTurn(changedFiles: nil, changedFilesTotal: nil, checkpoints: nil, createdAt: iso(createdAt),
           endedAt: nil, error: nil, git: nil, id: id, model: nil, persona: nil, ranOn: macRanOn(),
           retryOfTurnID: nil, runtime: runtime, startedAt: nil,
           startedBy: startedBy ?? userStartedBy(), status: status, stopReason: nil,
           threadID: threadID, usage: nil)
}

func makeItem(id: String, threadID: String, turnID: String, kind: TPItemKind,
              status: TPItemStatus, text: String? = nil) -> TPItem {
    TPItem(agentName: nil, approval: nil, attachments: nil, commandID: nil, completedAt: nil,
           context: nil, createdAt: iso(), fullTextAttachmentID: nil, id: id, kind: kind,
           notice: nil, parentItemID: nil, plan: nil, question: nil, sentFrom: nil,
           status: status, text: text, threadID: threadID, toolCall: nil, truncated: nil,
           turnID: turnID)
}

func makeApproval(requestID: String, expiresAt: String? = nil) -> TPApproval {
    TPApproval(detail: nil, expiresAt: expiresAt, kind: .tool,
               options: [TPApprovalOption(kind: .allowOnce, label: "Allow once", optionID: "allow_once"),
                         TPApprovalOption(kind: .rejectOnce, label: "Reject", optionID: "reject_once")],
               payloadJSON: nil, requestID: requestID, resolution: nil, risk: nil,
               summary: "Run a command", toolItemID: nil)
}

func makeQuestion(requestID: String, expiresAt: String? = nil) -> TPQuestion {
    TPQuestion(danger: nil, expiresAt: expiresAt,
               questions: [TPQuestionPrompt(allowFreeText: true, choices: nil, inputType: .text,
                                            multiSelect: false, prompt: "Which file?", questionID: "q1")],
               requestID: requestID, resolution: nil)
}

func makeApprovalItem(id: String, threadID: String, turnID: String, approval: TPApproval) -> TPItem {
    TPItem(agentName: nil, approval: approval, attachments: nil, commandID: nil, completedAt: nil,
           context: nil, createdAt: iso(), fullTextAttachmentID: nil, id: id, kind: .approval,
           notice: nil, parentItemID: nil, plan: nil, question: nil, sentFrom: nil,
           status: .inProgress, text: nil, threadID: threadID, toolCall: nil, truncated: nil,
           turnID: turnID)
}

func makeQuestionItem(id: String, threadID: String, turnID: String, question: TPQuestion) -> TPItem {
    TPItem(agentName: nil, approval: nil, attachments: nil, commandID: nil, completedAt: nil,
           context: nil, createdAt: iso(), fullTextAttachmentID: nil, id: id, kind: .question,
           notice: nil, parentItemID: nil, plan: nil, question: question, sentFrom: nil,
           status: .inProgress, text: nil, threadID: threadID, toolCall: nil, truncated: nil,
           turnID: turnID)
}

func makeNoticeItem(id: String, threadID: String, turnID: String, notice: TPNotice) -> TPItem {
    TPItem(agentName: nil, approval: nil, attachments: nil, commandID: nil, completedAt: nil,
           context: nil, createdAt: iso(), fullTextAttachmentID: nil, id: id, kind: .notice,
           notice: notice, parentItemID: nil, plan: nil, question: nil, sentFrom: nil,
           status: .completed, text: nil, threadID: threadID, toolCall: nil, truncated: nil,
           turnID: turnID)
}

func makeApprovalPrompt(id: String, threadID: String) -> AgentPermissionPrompt {
    AgentPermissionPrompt(id: id, conversationID: threadID, runID: UUID(),
                          title: "Run a command", detail: "touch /tmp/x")
}

// ───────────────────────────── the store double ──────────────────────────────

final class RecordingStore: TurnEngineStore {
    private(set) var storedThreads: [String: TPThread] = [:]
    private(set) var storedTurns: [String: TPTurn] = [:]
    private(set) var storedItems: [String: TPItem] = [:]
    private(set) var storedBindings: [String: RuntimeBinding] = [:]
    private(set) var appliedStamps: [TPEventStamp] = []
    private(set) var appliedEvents: [TPDurableEvent] = []
    private(set) var batches: [TurnWriteBatch] = []
    private(set) var commands: [String: TurnCommandRecord] = [:]

    /// Rises once per `apply`; a subscriber can prove the write happened first.
    private(set) var storeVersion = 0
    private(set) var appliedThreadIDs: [String] = []
    func stampedEvent(at index: Int) -> (TPEventStamp, TPDurableEvent)? {
        guard index < appliedStamps.count, index < appliedEvents.count else { return nil }
        return (appliedStamps[index], appliedEvents[index])
    }
    func lastSeq(threadID: String) -> Int {
        zip(appliedStamps, appliedThreadIDs).filter { $0.1 == threadID }.map(\.0.seq).max() ?? 0
    }

    private var seqByThread: [String: Int] = [:]
    private var originSeqByThread: [String: Int] = [:]

    func seed(thread: TPThread) { storedThreads[thread.id] = thread }
    func seed(turn: TPTurn) { storedTurns[turn.id] = turn }
    func seed(item: TPItem) { storedItems[item.id] = item }
    func seed(binding: RuntimeBinding?, threadID: String, runtime: TPRuntime) {
        storedBindings["\(threadID)|\(runtime.rawValue)"] = binding
    }

    func thread(id: String) throws -> TPThread? { storedThreads[id] }
    func turn(id: String) throws -> TPTurn? { storedTurns[id] }
    func item(id: String) throws -> TPItem? { storedItems[id] }
    func turns(threadID: String) throws -> [TPTurn] {
        storedTurns.values.filter { $0.threadID == threadID }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    func allTurns() throws -> [TPTurn] {
        storedTurns.values.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    func items(turnID: String) throws -> [TPItem] {
        storedItems.values.filter { $0.turnID == turnID }.sorted { $0.id < $1.id }
    }
    func attachment(id: String) throws -> TPAttachment? { nil }
    func binding(threadID: String, runtime: TPRuntime) throws -> RuntimeBinding? {
        storedBindings["\(threadID)|\(runtime.rawValue)"]
    }

    func apply(_ batch: TurnWriteBatch) throws -> [TPEventStamp] {
        batches.append(batch)
        var result: [TPEventStamp] = []
        for event in batch.events {
            let threadID = event.threadID
            let seq = (seqByThread[threadID] ?? 0) + 1
            let originSeq = (originSeqByThread[threadID] ?? 0) + 1
            seqByThread[threadID] = seq
            originSeqByThread[threadID] = originSeq
            let stamp = TPEventStamp(seq: seq, origin: "self", originSeq: originSeq, at: iso())
            appliedStamps.append(stamp)
            appliedEvents.append(event)
            appliedThreadIDs.append(threadID)
            result.append(stamp)
        }
        if let thread = batch.thread { storedThreads[thread.id] = thread }
        for turn in batch.turns { storedTurns[turn.id] = turn }
        for item in batch.items { storedItems[item.id] = item }
        for write in batch.bindings {
            storedBindings["\(write.threadID)|\(write.runtime.rawValue)"] = write.binding
        }
        storeVersion += 1
        return result
    }

    func commandRecord(commandID: String) throws -> TurnCommandRecord? { commands[commandID] }
    func storeCommandRecord(_ record: TurnCommandRecord) throws { commands[record.commandID] = record }
}

// ───────────────────────────── the runtime double ────────────────────────────

actor TestGate {
    private var open: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func wait(_ key: String) async {
        if open.contains(key) { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }
    func release(_ key: String) {
        open.insert(key)
        for continuation in waiters.removeValue(forKey: key) ?? [] { continuation.resume() }
    }
}

final class GatedRuntime: AgentRuntime {
    let kind: AgentRuntimeKind
    let capabilities = AgentRuntimeCapabilities(images: false, nativeTools: false, skills: false,
                                                externalMCP: false, permissions: true)
    let gate = TestGate()
    var holdThreads: Set<String> = ["*"]
    var script: (AgentTurnRequest) -> [AgentRuntimeEvent] = { _ in [] }
    var finalText = "done"
    var failure: AgentRuntimeFailure?
    var failureByThread: [String: AgentRuntimeFailure] = [:]
    private(set) var startedThreads: [String] = []
    private(set) var startedTurnIDs: [UUID] = []
    private(set) var cancelledTurnIDs: [UUID] = []
    private var threadByTurnID: [UUID: String] = [:]

    init(kind: AgentRuntimeKind = .opencode) { self.kind = kind }

    func status() async -> AgentRuntimeStatus {
        AgentRuntimeStatus(health: .healthy, version: "test", detail: nil)
    }

    func run(_ request: AgentTurnRequest, binding: RuntimeBinding?,
             emit: @escaping (AgentRuntimeEvent) -> Void) async throws -> AgentTurnResult {
        startedThreads.append(request.conversationID)
        startedTurnIDs.append(request.turnID)
        threadByTurnID[request.turnID] = request.conversationID
        emit(.started(externalSessionID: "external-\(request.turnID.uuidString)"))
        for event in script(request) { emit(event) }
        if holdThreads.contains("*") || holdThreads.contains(request.conversationID) {
            await gate.wait(request.conversationID)
        }
        if cancelledTurnIDs.contains(request.turnID) { throw CancellationError() }
        if let failure = failureByThread[request.conversationID] { throw failure }
        if let failure { throw failure }
        return AgentTurnResult(externalSessionID: "external-\(request.turnID.uuidString)",
                               runtimeVersion: "test", text: finalText, usage: nil)
    }

    func cancel(turnID: UUID) async {
        cancelledTurnIDs.append(turnID)
        if let threadID = threadByTurnID[turnID] { await gate.release(threadID) }
    }

    func release(_ threadID: String) async { await gate.release(threadID) }
}

// ───────────────────────────── the driver double ─────────────────────────────

final class FakeDriver: TurnRuntimeDriver {
    var runtimes: [TPRuntime: GatedRuntime] = [.opencode: GatedRuntime(), .codex: GatedRuntime(kind: .codex),
                                               .claude: GatedRuntime(kind: .claude)]
    var savedBindings: [String: RuntimeBinding] = [:]
    var delegatesByThread: [String: [TPPersonaDelegate]] = [:]
    private(set) var madeRequests: [(threadID: String, todayContext: String, delegatesBlock: String)] = []
    private(set) var madeTurnIDs: [String] = []
    private(set) var childRequests: [AgentTurnRequest] = []

    func runtime(for kind: TPRuntime) throws -> any AgentRuntime {
        guard let runtime = runtimes[kind] else {
            throw TurnEngineError.protocolError(code: "runtime_unavailable",
                                                message: "no runtime for \(kind.rawValue)", retryable: false)
        }
        return runtime
    }
    func binding(threadID: String, runtime: TPRuntime) throws -> RuntimeBinding? {
        savedBindings["\(threadID)|\(runtime.rawValue)"]
    }
    func delegates(thread: TPThread) throws -> [TPPersonaDelegate] {
        delegatesByThread[thread.id] ?? []
    }
    func makeRequest(thread: TPThread, turn: TPTurn, text: String, attachments: [TPAttachment],
                     todayContext: String, delegatesBlock: String) throws -> AgentTurnRequest {
        madeRequests.append((thread.id, todayContext, delegatesBlock))
        madeTurnIDs.append(turn.id)
        return AgentTurnRequest(turnID: UUID(), conversationID: thread.id, assistant: nil,
                                priorMessages: [], prompt: text, screenshots: [],
                                workingDirectory: URL(fileURLWithPath: thread.workspaceRoot.path),
                                extraWritableRoots: [], trustProfile: .workspace, model: nil,
                                instructions: delegatesBlock)
    }
    func childRequest(thread: TPThread, turn: TPTurn, delegate: DelegateTask) throws -> AgentTurnRequest {
        let request = AgentTurnRequest(turnID: UUID(), conversationID: "child-\(delegate.persona)",
                                       assistant: nil, priorMessages: [], prompt: delegate.task,
                                       screenshots: [], workingDirectory: URL(fileURLWithPath: thread.workspaceRoot.path),
                                       extraWritableRoots: [], trustProfile: .workspace, model: nil,
                                       instructions: "")
        childRequests.append(request)
        return request
    }
    func bindingAfterStart(_ binding: RuntimeBinding?, externalSessionID: String,
                           request: AgentTurnRequest) -> RuntimeBinding {
        var value = binding ?? RuntimeBinding()
        value.externalSessionID = externalSessionID
        value.state = .clean
        return value
    }
}

// ───────────────────────────── workspace and clock doubles ───────────────────

final class FakeWorkspace: TurnWorkspace {
    var beforeName: String? = "refs/atika/checkpoints/t/t-before"
    var finishedState = TurnCheckpointState(
        before: "refs/atika/checkpoints/t/t-before",
        after: "refs/atika/checkpoints/t/t-after",
        changedFiles: [TPChangedFile(added: 3, path: "a.txt", removed: 1)],
        changedFilesTotal: 1,
        git: TPTurnGit(branch: "main", dirty: true, headCommit: "abc", pushed: false,
                       unpushedCount: 1, upstreamRef: "origin/main"),
        warning: nil)
    private(set) var began: [String] = []
    private(set) var finished: [String] = []
    func begin(thread: TPThread, turn: TPTurn) -> String? {
        began.append(turn.id)
        return beforeName
    }
    func finish(thread: TPThread, turn: TPTurn) -> TurnCheckpointState {
        finished.append(turn.id)
        return finishedState
    }
}

final class TestClock: TurnClock {
    var current = turnEngineFixedDate
    func now() -> Date { current }
    func sleep(seconds: Double) async { current = current.addingTimeInterval(seconds) }
}

final class RecordingActivity: TurnActivityAssertion {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    func begin() { beginCount += 1 }
    func end() { endCount += 1 }
}

// ───────────────────────────── the engine under test ─────────────────────────

final class EngineHarness {
    let store = RecordingStore()
    let driver = FakeDriver()
    let workspace = FakeWorkspace()
    let clock = TestClock()
    let activity = RecordingActivity()
    let engine: TurnEngine
    let signals: SignalRecorder
    let generalFolder: URL
    var limits: TurnAdmissionLimits

    init(limits: TurnAdmissionLimits = TurnAdmissionLimits()) {
        self.limits = limits
        let general = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vf-turn-\(UUID().uuidString)/projects/general", isDirectory: true)
        try? FileManager.default.createDirectory(at: general, withIntermediateDirectories: true)
        self.generalFolder = general
        self.signals = SignalRecorder()
        self.engine = TurnEngine(store: store, driver: driver, workspace: workspace,
                                 limits: limits, generalProjectFolder: general, clock: clock,
                                 activity: activity)
        _ = engine.subscribe { [signals, store] signal in
            signals.record(signal, storeVersion: store.storeVersion,
                           storedEventCount: store.appliedEvents.count,
                           eventPresent: {
                               if case let .stored(_, event) = signal {
                                   return store.appliedEvents.contains(event)
                               }
                               return true
                           }())
        }
    }

    func startThread(id: String, runtime: TPRuntime = .opencode) async -> TPThread {
        let request = CreateThreadRequest(projectID: "p1", personaID: nil, personaName: nil,
                                          runtime: runtime, model: nil, reasoningEffort: nil,
                                          trustProfile: .workspace, ownWorkingCopy: false,
                                          startedBy: userStartedBy(), requestExpirySec: nil,
                                          message: nil, attachmentIDs: [], sentFrom: nil)
        do {
            let outcome = try await engine.createThread(request)
            return outcome.thread
        } catch {
            fatalError("createThread failed: \(error)")
        }
    }
}

final class SignalRecorder {
    private(set) var signals: [TurnEngineSignal] = []
    private(set) var storedStoreVersionAtSignal: [Int] = []
    private(set) var storedEventCountAtSignal: [Int] = []
    private(set) var storedEventWasPresentAtSignal: [Bool] = []

    func record(_ signal: TurnEngineSignal, storeVersion: Int, storedEventCount: Int, eventPresent: Bool) {
        signals.append(signal)
        if case .stored = signal {
            storedStoreVersionAtSignal.append(storeVersion)
            storedEventCountAtSignal.append(storedEventCount)
            storedEventWasPresentAtSignal.append(eventPresent)
        }
    }
    var storedSignals: [(TPEventStamp, TPDurableEvent)] {
        signals.compactMap {
            if case let .stored(stamp, event) = $0 { return (stamp, event) }
            return nil
        }
    }
    var deltas: [TPLiveDelta] {
        signals.compactMap { if case let .delta(delta) = $0 { return delta }; return nil }
    }
}

enum TurnSuitePaths {
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)                       // tests/turn_engine/support.swift
            .deletingLastPathComponent()                      // tests/turn_engine
            .deletingLastPathComponent()                      // tests
            .deletingLastPathComponent()                      // repository
    }
}
