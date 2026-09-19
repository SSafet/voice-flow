import Foundation
import GRDB

// V8 through the real store (06 §3.12 and V1's 06 §3.2): the outside-session
// adapter writes the contract's records into the one `threads.sqlite` through
// V1's `ThreadStore`, so the thread, its turns, its items and its events land
// in the store every other package reads, with the word `self` on disk for the
// home id. This suite compiles V1's store and V8's adapter; it is the one that
// proves the two fit.

func storeSuiteConfigRoot(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("vf-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func storeSuitePaths(_ configRoot: URL) -> VoiceFlowPaths {
    VoiceFlowPaths(environment: [VoiceFlowPaths.configRootEnvironmentKey: configRoot.path])
}

let suiteRoot = storeSuiteConfigRoot("v8-store")
defer { try? FileManager.default.removeItem(at: suiteRoot) }

let pool = try ThreadDatabase.open(at: ThreadDatabase.url(configRoot: suiteRoot))
let paths = storeSuitePaths(suiteRoot)
let store = ThreadStore(pool: pool, paths: paths, homeID: { "h_mac_one" })
let registry = ProjectRegistry(store: store, paths: paths)

let general = try registry.ensureGeneral()
let pantriaFolder = suiteRoot.appendingPathComponent("pantria", isDirectory: true)
try? FileManager.default.createDirectory(at: pantriaFolder, withIntermediateDirectories: true)
let pantria = try registry.create(commandID: "proj-1", name: "pantria",
                                  path: pantriaFolder.path, gitRemote: nil)

let now = TestNow()
let clock = now
let questions = TestQuestions()
let sessions = MCPSessionRegistry()
let bridge = OutsideSessionBridge(store: StoreOutsideSessionStore(store: store),
                                  projects: RegistryOutsideSessionProjects(registry: registry),
                                  questions: questions, sessions: sessions,
                                  now: { clock.read() }, newID: { UUID().uuidString })

// 1. A report after a name and a working directory creates a real thread row.
_ = try await bridge.seen(sessionID: "sess-store-1", client: "claude-code")
try await bridge.setSessionName(sessionID: "sess-store-1", name: "pantria — checkout",
                                workingDirectory: pantriaFolder.appendingPathComponent("Sources").path)
_ = try await bridge.report(sessionID: "sess-store-1", summary: "Started", details: "",
                            question: nil, timeoutSeconds: nil)

let written = try store.thread("sess-store-1")
checkEqual("the thread is in the store", written?.id, "sess-store-1")
checkEqual("its runtime is external", written?.runtime, .external)
checkEqual("it is filed under the project holding the working directory",
           written?.projectID, pantria.id)
checkEqual("it offers no controls", written?.supports, [])
checkEqual("its external client is the MCP client name", written?.externalClient, "claude-code")

// 2. The store writes the word `self` for the home id, never the real one.
let storedHomeID = try pool.read { db in
    try String.fetchOne(db, sql: "SELECT home_id FROM threads WHERE id = ?", arguments: ["sess-store-1"])
}
checkEqual("the home id on disk is the word self", storedHomeID, "self")

// 3. The person's message, the report and the listen are turns and items in the
//    one store, and every write left a durable event.
let queued = try await bridge.send(threadID: "sess-store-1", text: "how is it going?",
                                   commandID: "cmd-store-1")
let delivered = try bridge.checkMessages(sessionID: "sess-store-1")
checkEqual("the person's words were delivered", delivered.message?.text, "how is it going?")
_ = try await bridge.report(sessionID: "sess-store-1", summary: "Almost done", details: "",
                            question: nil, timeoutSeconds: nil)
_ = try bridge.checkMessages(sessionID: "sess-store-1")

let openPage = try store.open(threadID: "sess-store-1", sinceSeq: nil)
let kinds = openPage.items.map(\.kind)
check("the store holds the user message", kinds.contains(.userMessage))
check("the store holds the report", kinds.contains(.assistantMessage))
let eventCount = try pool.read { db in
    try Int.fetchOne(db, sql: "SELECT count(*) FROM thread_events WHERE thread_id = ?",
                     arguments: ["sess-store-1"]) ?? 0
}
check("the writes left durable events", eventCount > 0, "\(eventCount)")
checkEqual("the queued turn completed",
           openPage.turns.first { $0.id == queued.id }?.status, .completed)

// 4. Ending the session archives the real thread and refuses the next send.
_ = try await bridge.close(sessionID: "sess-store-1")
let archived = try store.thread("sess-store-1")
check("the archived thread has an archive time", archived?.archivedAt != nil)
checkEqual("the store's archived_at column agrees",
           try pool.read { db in
               try String.fetchOne(db, sql: "SELECT archived_at FROM threads WHERE id = ?",
                                   arguments: ["sess-store-1"])
           } != nil, true)
check("the archived thread carries the gone notice",
      try store.open(threadID: "sess-store-1", sinceSeq: nil).items.contains { $0.kind == .notice })
await expectOutsideSessionErrorAsync("the archived thread refuses a send at once",
                                     code: "runtime_unavailable") {
    _ = try await bridge.send(threadID: "sess-store-1", text: "hello?",
                              commandID: "cmd-store-2")
}

finishOutsideSessions("outside sessions: store")
