import Foundation
import GRDB

// Shared helpers for the four V1 suites (thread_store_records,
// thread_store_events, thread_store_projects, thread_store_recovery).
//
// Declarations only: a Swift file that is not `main.swift` may not carry
// top-level statements, so every suite's own assertions live in its
// `main.swift` and this file only builds records and scaffolding.
//
// Nothing here asserts anything about the code under test. The record
// builders below are plain contract values (swift/Generated/PlatformContracts.swift)
// with the fields a suite needs; a suite that wants a different value passes it.

// MARK: - assertions

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
        exit(1)
    }
}

/// Fails unless `body` refuses with exactly this contract error code. A
/// refusal is part of the public surface, so the code is compared, never the
/// message text.
func requireRefusal(_ code: TPErrorCode, _ message: String, _ body: () throws -> Void) {
    do {
        try body()
    } catch let error as ThreadStoreError {
        guard error.code == code else {
            FileHandle.standardError.write(Data(
                "not ok - \(message): refused with \(error.code.rawValue), expected \(code.rawValue)\n".utf8))
            exit(1)
        }
        guard !error.message.isEmpty else {
            FileHandle.standardError.write(Data(
                "not ok - \(message): refusal carries no message\n".utf8))
            exit(1)
        }
        return
    } catch {
        FileHandle.standardError.write(Data(
            "not ok - \(message): threw \(error), expected \(code.rawValue)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("not ok - \(message): nothing was refused\n".utf8))
    exit(1)
}

func ok(_ message: String) { print("ok - \(message)") }

// MARK: - scaffolding

var fixtureFileManager: FileManager { FileManager.default }

/// A throwaway configuration root. Every suite works inside one so that no run
/// can reach `~/.config/voice-flow`.
func makeConfigRoot(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vf-\(label)-\(UUID().uuidString)", isDirectory: true)
    do {
        try fixtureFileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("not ok - could not make a config root: \(error)\n".utf8))
        exit(1)
    }
    return url
}

func makeFolder(_ url: URL) -> URL {
    do {
        try fixtureFileManager.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("not ok - could not make \(url.path): \(error)\n".utf8))
        exit(1)
    }
    return url
}

/// The path holder pointed at a throwaway root, so nothing can reach
/// `~/.config/voice-flow`.
func makePaths(_ configRoot: URL) -> VoiceFlowPaths {
    VoiceFlowPaths(environment: [VoiceFlowPaths.configRootEnvironmentKey: configRoot.path])
}

/// Opens a store on a fresh file inside `configRoot`, through the one migrator
/// K8 owns, so a suite exercises exactly the path the app takes.
func openStore(configRoot: URL, homeID: String = "h_mac_one") throws -> (DatabasePool, ThreadStore) {
    let pool = try ThreadDatabase.open(at: ThreadDatabase.url(configRoot: configRoot))
    let store = ThreadStore(pool: pool, paths: makePaths(configRoot), homeID: { homeID })
    return (pool, store)
}

// MARK: - record builders

let fixtureNow = "2026-09-19T10:00:00Z"

func makeProject(
    id: String,
    name: String,
    path: String,
    isGeneral: Bool = false,
    gitRemote: String? = nil,
    gitDefaultBranch: String? = nil,
    remoteAccess: TPRemoteAccess = .readWrite,
    archivedAt: String? = nil,
    version: Int = 1,
    homeID: String = "h_mac_one",
    createdAt: String = fixtureNow
) -> TPProject {
    TPProject(
        archivedAt: archivedAt, available: true, createdAt: createdAt, deletedAt: nil,
        gitDefaultBranch: gitDefaultBranch, gitRemote: gitRemote, homeID: homeID, id: id,
        isGeneral: isGeneral, name: name, path: path, remoteAccess: remoteAccess,
        version: version)
}

func makeWorkspaceRoot(projectID: String, path: String) -> TPWorkspaceRoot {
    TPWorkspaceRoot(baseCommit: nil, branch: nil, kind: .project, path: path, rootID: projectID)
}

func makeThread(
    id: String,
    projectID: String,
    title: String = "A thread",
    activity: TPThreadActivity = .idle,
    attention: TPThreadAttention? = nil,
    lastTurn: TPThreadLastTurn? = nil,
    lastActivityAt: String = fixtureNow,
    lastReadAt: String? = fixtureNow,
    archivedAt: String? = nil,
    deletedAt: String? = nil,
    workspaceRoot: TPWorkspaceRoot? = nil,
    branch: String? = nil,
    personaID: String? = "flora",
    runtime: TPRuntime = .opencode,
    version: Int = 1,
    homeID: String = "h_mac_one"
) -> TPThread {
    TPThread(
        activity: activity, archivedAt: archivedAt, attention: attention, branch: branch,
        cloud: nil, createdAt: fixtureNow, deletedAt: deletedAt, externalClient: nil,
        homeID: homeID, id: id, lastActivityAt: lastActivityAt, lastReadAt: lastReadAt,
        lastTurn: lastTurn, mirrorBlocked: nil, model: "deepseek/deepseek-v4.1-flash",
        personaID: personaID, personaName: personaID == nil ? nil : "FLORA", pinnedAt: nil,
        pinnedSlot: nil, projectID: projectID, reasoningEffort: nil, runtime: runtime,
        startedBy: makeStartedBy(), supports: [.stop, .model], title: title,
        titleSource: .auto, trustProfile: .workspace, version: version,
        workspaceRoot: workspaceRoot ?? makeWorkspaceRoot(projectID: projectID, path: "/tmp/\(projectID)"))
}

func makeStartedBy(_ kind: TPStartedByKind = .user) -> TPStartedBy {
    TPStartedBy(kind: kind, occurrenceKey: nil, runID: nil, triggerID: nil, triggerName: nil)
}

func makeRanOn(homeID: String = "h_mac_one", label: String = "Mac mini") -> TPRanOn {
    TPRanOn(homeID: homeID, kind: .mac, label: label)
}

func makeTurn(
    id: String,
    threadID: String,
    status: TPTurnStatus = .completed,
    createdAt: String = fixtureNow,
    endedAt: String? = "2026-09-19T10:00:30Z",
    git: TPTurnGit? = nil,
    checkpoints: TPTurnCheckpoints? = nil,
    changedFiles: [TPChangedFile]? = nil,
    stopReason: TPStopReason? = .endTurn,
    reasoningEffort: String? = nil
) -> TPTurn {
    TPTurn(
        changedFiles: changedFiles, changedFilesTotal: changedFiles?.count, checkpoints: checkpoints,
        createdAt: createdAt, endedAt: endedAt, error: nil, git: git, id: id,
        model: "deepseek/deepseek-v4.1-flash", persona: TPTurnPersona(id: "flora", name: "FLORA"),
        ranOn: makeRanOn(), reasoningEffort: reasoningEffort, retryOfTurnID: nil, runtime: .opencode, startedAt: createdAt,
        startedBy: makeStartedBy(), status: status, stopReason: stopReason, threadID: threadID,
        usage: nil)
}

func makeItem(
    id: String,
    turnID: String,
    threadID: String,
    kind: TPItemKind = .userMessage,
    status: TPItemStatus = .completed,
    text: String? = "hello",
    attachments: [TPAttachment]? = nil,
    notice: TPNotice? = nil,
    toolCall: TPToolCall? = nil,
    truncated: Bool? = nil,
    fullTextAttachmentID: String? = nil,
    createdAt: String = fixtureNow
) -> TPItem {
    TPItem(
        agentName: nil, approval: nil, attachments: attachments, commandID: nil,
        completedAt: status == .inProgress ? nil : createdAt, context: nil, createdAt: createdAt,
        fullTextAttachmentID: fullTextAttachmentID, id: id, kind: kind, notice: notice,
        parentItemID: nil, plan: nil, question: nil, sentFrom: nil, status: status, text: text,
        threadID: threadID, toolCall: toolCall, truncated: truncated, turnID: turnID)
}

func makeMark(n: Int = 1, note: String? = "look here", underText: String? = "Total: 42") -> TPMark {
    TPMark(
        box: [10, 20, 120, 60], center: nil, color: .amber, from: nil, kind: .rect, label: nil,
        n: n, note: note, origin: nil, points: nil, stroke: 3, to: nil, underText: underText)
}

func makeContext() -> TPContext {
    TPContext(
        app: "Safari", bundleID: "com.apple.Safari",
        display: TPContextDisplay(heightPt: 1080, index: 0, scale: 2, uuid: "D-1", widthPt: 1920),
        pointer: [400, 300], contextPrivate: false, url: nil, windowBox: [0, 0, 1920, 1080],
        windowTitle: "Bank")
}

func makeAttachment(
    id: String,
    threadID: String,
    kind: TPAttachmentKind = .annotatedScreenshot,
    name: String = "screen.png",
    mime: String = "image/png",
    marks: [TPMark]? = nil,
    context: TPContext? = nil,
    modelText: String? = nil,
    captureID: String? = nil,
    sizeBytes: Int = 4096
) -> TPAttachment {
    TPAttachment(
        bytes: TPAttachmentBytes(artifactID: nil, state: .onHome), captureID: captureID,
        context: context, createdAt: fixtureNow, forModel: nil, height: 1080, id: id, kind: kind,
        marks: marks, mime: mime, modelText: modelText, name: name,
        sha256: String(repeating: "a", count: 64), sizeBytes: sizeBytes, threadID: threadID,
        width: 1920)
}

func makeDurableEvent(_ type: TPEventType, threadID: String,
                      thread: TPThread? = nil, turn: TPTurn? = nil, item: TPItem? = nil) -> TPDurableEvent {
    TPDurableEvent(item: item, thread: thread, threadID: threadID, turn: turn, type: type)
}

// MARK: - a sink that records what the store handed it

/// Stands in for the channel outbox V9 registers. It records, and it can be
/// told to throw, which is how a suite proves the append happens inside the
/// store's own transaction.
final class RecordingEventSink: ThreadEventSink {
    private(set) var seen: [StoredEvent] = []
    var failNext = false

    func append(_ events: [StoredEvent], in db: Database) throws {
        if failNext {
            failNext = false
            throw ThreadStoreError(code: .invalidParams, message: "the sink refused this batch")
        }
        seen.append(contentsOf: events)
    }
}

/// Collects what a store observation delivered, across queues.
final class ObservationBox {
    private let lock = NSLock()
    private var values: [[TPThread]] = []

    func record(_ threads: [TPThread]) {
        lock.lock(); defer { lock.unlock() }
        values.append(threads)
    }

    var latest: [TPThread] {
        lock.lock(); defer { lock.unlock() }
        return values.last ?? []
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }
}

/// A git probe whose answers the suite decides, so the registry's behaviour is
/// tested without a repository on disk. `SystemGitProbe` is what the app uses.
final class StubGitProbe: ProjectGitProbe {
    var remotes: [String: String] = [:]
    var branches: [String: String] = [:]
    private(set) var asked: [String] = []

    func remote(at folder: URL) -> String? {
        asked.append(folder.standardizedFileURL.path)
        return remotes[folder.standardizedFileURL.path]
    }

    func defaultBranch(at folder: URL) -> String? {
        branches[folder.standardizedFileURL.path]
    }
}
