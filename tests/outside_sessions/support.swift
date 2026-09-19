import Foundation

// Shared helpers and doubles for work package V8's suites. This file is
// compiled into every `outside_sessions*` suite beside the package's own
// sources. It names the package's public surface and no private function.

// The suites compile the app sources without `swift/Core.swift`, the way every
// other suite in this repository does, so they carry its logging stub.
func vflog(_ message: String) {}

var osChecks = 0
var osFailures: [String] = []

func check(_ what: String, _ condition: Bool, _ detail: String = "") {
    osChecks += 1
    if !condition { osFailures.append(detail.isEmpty ? what : "\(what): \(detail)") }
}

func checkEqual<T: Equatable>(_ what: String, _ got: T, _ expected: T) {
    check(what, got == expected, "\(got) is not \(expected)")
}

func expectOutsideSessionError(_ what: String, _ body: () throws -> Void, code: String) {
    osChecks += 1
    do {
        try body()
        osFailures.append("\(what): no error was thrown")
    } catch let error as OutsideSessionError {
        if error.code != code {
            osFailures.append("\(what): error code \"\(error.code)\" is not \"\(code)\"")
        }
    } catch {
        osFailures.append("\(what): unexpected error \(error)")
    }
}

func expectOutsideSessionErrorAsync(_ what: String, code: String,
                                    _ body: () async throws -> Void) async {
    osChecks += 1
    do {
        try await body()
        osFailures.append("\(what): no error was thrown")
    } catch let error as OutsideSessionError {
        if error.code != code {
            osFailures.append("\(what): error code \"\(error.code)\" is not \"\(code)\"")
        }
    } catch {
        osFailures.append("\(what): unexpected error \(error)")
    }
}

func finishOutsideSessions(_ suite: String) -> Never {
    if osFailures.isEmpty {
        print("\(suite): \(osChecks) checks, all pass")
        exit(0)
    }
    for failure in osFailures {
        FileHandle.standardError.write(Data("not ok - \(failure)\n".utf8))
    }
    FileHandle.standardError.write(Data("\(suite): \(osFailures.count) of \(osChecks) checks fail\n".utf8))
    exit(1)
}

// ───────────────────────────── contract builders ─────────────────────────────

let osFixedDate: Date = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: "2026-09-20T10:00:00Z")!
}()

func iso(_ date: Date = osFixedDate) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func osProject(id: String, name: String, path: String, isGeneral: Bool = false) -> TPProject {
    TPProject(archivedAt: nil, available: true, createdAt: iso(), deletedAt: nil,
              gitDefaultBranch: nil, gitRemote: nil, homeID: "self", id: id, isGeneral: isGeneral,
              name: name, path: path, remoteAccess: .readWrite, version: 1)
}

func osThread(id: String, projectID: String, runtime: TPRuntime = .external,
              title: String = "outside", activity: TPThreadActivity = .idle,
              archivedAt: String? = nil, version: Int = 1) -> TPThread {
    TPThread(activity: activity, archivedAt: archivedAt, attention: nil, branch: nil, cloud: nil,
             createdAt: iso(), deletedAt: nil, externalClient: "claude-code", homeID: "self",
             id: id, lastActivityAt: iso(), lastReadAt: iso(), lastTurn: nil, mirrorBlocked: nil,
             model: nil, personaID: nil, personaName: nil, pinnedAt: nil, pinnedSlot: nil,
             projectID: projectID, reasoningEffort: nil, runtime: runtime,
             startedBy: TPStartedBy(kind: .external, occurrenceKey: nil, runID: nil, triggerID: nil,
                                    triggerName: nil),
             supports: [], title: title, titleSource: .auto, trustProfile: nil, version: version,
             workspaceRoot: TPWorkspaceRoot(baseCommit: nil, branch: nil, kind: .project,
                                            path: "/tmp/\(projectID)", rootID: projectID))
}

func osTurn(id: String, threadID: String, status: TPTurnStatus,
            createdAt: Date = osFixedDate) -> TPTurn {
    TPTurn(changedFiles: nil, changedFilesTotal: nil, checkpoints: nil, createdAt: iso(createdAt),
           endedAt: nil, error: nil, git: nil, id: id, model: nil, persona: nil,
           ranOn: TPRanOn(homeID: "self", kind: .mac, label: "This Mac"), retryOfTurnID: nil,
           runtime: .external, startedAt: nil,
           startedBy: TPStartedBy(kind: .external, occurrenceKey: nil, runID: nil, triggerID: nil,
                                  triggerName: nil),
           status: status, stopReason: nil, threadID: threadID, usage: nil)
}

func osItem(id: String, threadID: String, turnID: String, kind: TPItemKind,
            status: TPItemStatus, text: String? = nil, commandID: String? = nil) -> TPItem {
    TPItem(agentName: nil, approval: nil, attachments: nil, commandID: commandID, completedAt: nil,
           context: nil, createdAt: iso(), fullTextAttachmentID: nil, id: id, kind: kind,
           notice: nil, parentItemID: nil, plan: nil, question: nil, sentFrom: nil,
           status: status, text: text, threadID: threadID, toolCall: nil, truncated: nil,
           turnID: turnID)
}

func osQuestionAnswer(_ text: String) -> TPQuestionResolution {
    TPQuestionResolution(answeredBy: nil,
                         answers: [TPQuestionAnswer(choiceIDS: nil, questionID: "q1", text: text)],
                         at: iso(), outcome: .answered)
}

func osExpiredQuestion() -> TPQuestionResolution {
    TPQuestionResolution(answeredBy: nil, answers: nil, at: iso(), outcome: .expired)
}

// ───────────────────────────── the store double ──────────────────────────────
//
// V8 owns this narrow durability seam; the real one is the adapter over V1's
// ThreadStore, which the integration suite and the whole-package review compile.
// The double stores exactly the records the bridge hands it, so a suite can
// prove what the bridge wrote and in which order.

final class TestStore: OutsideSessionStore {
    private(set) var threadsByID: [String: TPThread] = [:]
    private(set) var turnsByThread: [String: [TPTurn]] = [:]
    private(set) var itemsByTurn: [String: [TPItem]] = [:]
    private(set) var batches: [OutsideSessionBatch] = []

    func seed(thread: TPThread) { threadsByID[thread.id] = thread }
    func seed(turn: TPTurn) { turnsByThread[turn.threadID, default: []].append(turn) }
    func seed(item: TPItem) { itemsByTurn[item.turnID, default: []].append(item) }

    func thread(id: String) throws -> TPThread? { threadsByID[id] }
    func threads(runtime: TPRuntime) throws -> [TPThread] {
        threadsByID.values.filter { $0.runtime == runtime }
    }
    func turns(threadID: String) throws -> [TPTurn] {
        (turnsByThread[threadID] ?? []).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }
    func items(threadID: String) throws -> [TPItem] {
        try turns(threadID: threadID).flatMap { itemsByTurn[$0.id] ?? [] }.sorted { $0.id < $1.id }
    }
    func apply(_ batch: OutsideSessionBatch) throws {
        batches.append(batch)
        if let thread = batch.thread { threadsByID[thread.id] = thread }
        for turn in batch.turns { turnsByThread[turn.threadID, default: []].append(turn) }
        for item in batch.items { itemsByTurn[item.turnID, default: []].append(item) }
    }

    func items(threadID: String) -> [TPItem] {
        (turnsByThread[threadID] ?? []).flatMap { itemsByTurn[$0.id] ?? [] }
    }

    // A suite's convenience, not part of the seam.
    func items(turnID: String) throws -> [TPItem] {
        (itemsByTurn[turnID] ?? []).sorted { $0.id < $1.id }
    }
}

// ───────────────────────────── the project double ────────────────────────────

final class TestProjects: OutsideSessionProjects {
    var general = osProject(id: "proj-general", name: "General",
                            path: "/tmp/vf/projects/general", isGeneral: true)
    var byID: [String: TPProject] = [:]

    func seed(_ project: TPProject) { byID[project.id] = project }
    func generalProject() throws -> TPProject { general }
    func project(containingPath path: String) throws -> TPProject? {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        return byID.values
            .filter { normalized == $0.path || normalized.hasPrefix($0.path + "/") }
            .sorted { $0.path.count > $1.path.count }
            .first
    }
}

// ───────────────────────────── the questions double ──────────────────────────

final class TestQuestions: OutsideSessionQuestions {
    struct Call: Equatable {
        let threadID: String
        let turnID: String
        let prompt: String
        let expiresAt: String
    }
    private(set) var calls: [Call] = []
    private(set) var cancels: [(threadID: String, turnID: String)] = []
    var resolution: TPQuestionResolution = osQuestionAnswer("yes")
    var onAsk: ((Call) -> Void)?

    func ask(threadID: String, turnID: String, prompt: String,
             expiresAt: String) async -> TPQuestionResolution {
        let call = Call(threadID: threadID, turnID: turnID, prompt: prompt, expiresAt: expiresAt)
        calls.append(call)
        onAsk?(call)
        return resolution
    }

    func cancel(threadID: String, turnID: String) async {
        cancels.append((threadID, turnID))
    }
}

// ───────────────────────────── the clock ─────────────────────────────────────

final class TestNow {
    var date: Date
    init(_ date: Date = osFixedDate) { self.date = date }
    func advance(_ seconds: Double) { date = date.addingTimeInterval(seconds) }
    func read() -> Date { date }
}

// ───────────────────────────── the harness ───────────────────────────────────

final class BridgeHarness {
    let store = TestStore()
    let projects = TestProjects()
    let questions = TestQuestions()
    let sessions = MCPSessionRegistry()
    let now: TestNow
    let bridge: OutsideSessionBridge

    init(start: Date = osFixedDate) {
        self.now = TestNow(start)
        let clock = now
        self.bridge = OutsideSessionBridge(store: store, projects: projects, questions: questions,
                                           sessions: sessions, now: { clock.read() },
                                           newID: { UUID().uuidString })
    }
}
