import Foundation

// V8, the outside-session thread in the store (06 §3.12): a session that does
// something the user can see becomes a thread with `runtime: external`; its id
// is the MCP session id; its title comes from set_session_name; it is filed
// under the project that holds its working directory, otherwise under General;
// it offers no controls; when the session is gone it is archived with a notice
// and a send is refused at once with its reason; when it returns it accepts
// messages again.
//
// Everything here goes through `OutsideSessionBridge`'s public surface.

let threadsHarness = BridgeHarness()
let bridge = threadsHarness.bridge
let store = threadsHarness.store
let projects = threadsHarness.projects
let now = threadsHarness.now

projects.seed(osProject(id: "proj-pantria", name: "pantria", path: "/tmp/vf/repos/pantria"))

// 1. Connecting alone is invisible: it creates no thread. Merely initializing
//    the MCP server — every Claude Code session does it — earns nothing.
_ = try await bridge.seen(sessionID: "sess-1", client: "claude-code")
checkEqual("a connection alone writes no thread", try store.threads(runtime: .external).count, 0)
checkEqual("the connection is known to the registry",
           threadsHarness.sessions.session("sess-1")?.client, "claude-code")

// 2. Naming alone is silent too, but the working directory is remembered.
let named = try await bridge.setSessionName(sessionID: "sess-1", name: "voice-flow — routing",
                                            workingDirectory: "/tmp/vf/repos/pantria/src")
check("naming a fresh session still writes no thread",
      try store.threads(runtime: .external).isEmpty)
checkEqual("set_session_name returns no thread before engagement", named == nil, true)

// 3. The first user-visible act creates the thread, filed under the project
//    that holds the remembered working directory.
_ = try await bridge.report(sessionID: "sess-1", summary: "Started", details: "Reading the tree",
                            question: nil, timeoutSeconds: nil)
let created = try store.thread(id: "sess-1")
check("the report created the thread", created != nil)
checkEqual("the thread id is the MCP session id", created?.id, "sess-1")
checkEqual("the runtime is external", created?.runtime, .external)
checkEqual("the external client is the MCP client name", created?.externalClient, "claude-code")
checkEqual("the title is the session's own name", created?.title, "voice-flow — routing")
checkEqual("a self-named session's title is custom", created?.titleSource, .custom)
checkEqual("the thread is filed under the project holding the working directory",
           created?.projectID, "proj-pantria")
checkEqual("the title is cut by the contract's first-line rule",
           created?.title, ContractTitle.firstLineTitle("voice-flow — routing"))
checkEqual("an external thread offers no controls", created?.supports, [])
checkEqual("an external thread has no persona", created?.personaID == nil, true)
checkEqual("an external thread has no model", created?.model == nil, true)
checkEqual("an external thread has no trust profile", created?.trustProfile == nil, true)
checkEqual("an external thread was started by an outside session", created?.startedBy?.kind, .external)
checkEqual("the working folder is the project folder",
           created?.workspaceRoot.path, "/tmp/vf/repos/pantria")
checkEqual("a project folder's rootId is the project id", created?.workspaceRoot.rootID, "proj-pantria")

// 4. A session with no working directory is filed under General, and its title
//    names the client and the folder.
_ = try await bridge.seen(sessionID: "sess-2", client: "codex")
_ = try await bridge.report(sessionID: "sess-2", summary: "Hello", details: "",
                            question: nil, timeoutSeconds: nil)
let general = try store.thread(id: "sess-2")
checkEqual("a session with no working directory lands under General",
           general?.projectID, "proj-general")
checkEqual("the default title names the client and the project", general?.title, "codex in General")

// 5. A working directory outside every project also lands under General.
_ = try await bridge.seen(sessionID: "sess-3", client: "claude-code")
try await bridge.setSessionName(sessionID: "sess-3", name: "loose",
                                workingDirectory: "/tmp/lonely")
_ = try await bridge.report(sessionID: "sess-3", summary: "Hi", details: "",
                            question: nil, timeoutSeconds: nil)
checkEqual("a path outside every project lands under General",
           try store.thread(id: "sess-3")?.projectID, "proj-general")

// 6. Filing happens once: a later working_directory does not move the thread.
try await bridge.setSessionName(sessionID: "sess-1", name: "voice-flow — routing",
                                workingDirectory: "/tmp/lonely")
checkEqual("a later working directory does not move a filed thread",
           try store.thread(id: "sess-1")?.projectID, "proj-pantria")
checkEqual("a later name still updates the title",
           try store.thread(id: "sess-1")?.title, ContractTitle.firstLineTitle("voice-flow — routing"))

// 7. A send to a live session queues a turn; the thread is idle until a listen.
let turn = try await bridge.send(threadID: "sess-1", text: "Are you done?",
                                 commandID: "cmd-send-1")
checkEqual("a send is accepted as a queued turn", turn.status, .queued)
checkEqual("the queued turn belongs to the external thread", turn.threadID, "sess-1")
checkEqual("the queued turn runs on this Mac", turn.ranOn.kind, .mac)

// 9. Ending the session archives the thread with a notice, and a send is
//    refused at once with the exact reason.
let closed = try await bridge.close(sessionID: "sess-1")
checkEqual("closing the session reports the archive", closed?.kind, .archived)
checkEqual("the closed thread is archived", try store.thread(id: "sess-1")?.archivedAt != nil, true)
let goneNotices = try store.items(threadID: "sess-1").filter { $0.kind == .notice }
check("the archived thread carries a notice", !goneNotices.isEmpty)
checkEqual("the notice is neutral, not a warning", goneNotices.last?.notice?.code, .note)
check("the notice says the session is gone",
      goneNotices.last?.notice?.message.contains("gone") ?? false,
      goneNotices.last?.notice?.message ?? "no notice")

await expectOutsideSessionErrorAsync("a send to a gone session is refused at once",
                                     code: "runtime_unavailable") {
    _ = try await bridge.send(threadID: "sess-1", text: "still there?",
                              commandID: "cmd-send-2")
}
do {
    _ = try await bridge.send(threadID: "sess-1", text: "still there?",
                              commandID: "cmd-send-3")
} catch let error as OutsideSessionError {
    checkEqual("the refusal carries the design's exact text", error.message,
               "this outside session is not connected")
} catch {
    check("the refusal is an OutsideSessionError", false, "\(error)")
}
checkEqual("the refused send wrote no turn",
           try store.turns(threadID: "sess-1").filter { $0.status == .queued }.count, 1)

// 10. The same session id returning unarchives the thread and accepts messages.
let returned = try await bridge.seen(sessionID: "sess-1", client: "claude-code")
checkEqual("the returning session gets its thread back", returned?.id, "sess-1")
checkEqual("the returning thread is not archived", returned?.archivedAt == nil, true)
_ = try await bridge.send(threadID: "sess-1", text: "back", commandID: "cmd-send-4")

// 11. A session silent past the two-hour window is not connected, even before a
//     reconcile pass; reconcile then archives its thread with one notice.
let stale = BridgeHarness()
_ = try await stale.bridge.seen(sessionID: "sess-stale", client: "claude-code")
_ = try await stale.bridge.report(sessionID: "sess-stale", summary: "hi", details: "",
                                  question: nil, timeoutSeconds: nil)
stale.now.advance(3 * 3600)
await expectOutsideSessionErrorAsync("a session silent past two hours is not connected",
                                     code: "runtime_unavailable") {
    _ = try await stale.bridge.send(threadID: "sess-stale", text: "ping",
                                    commandID: "cmd-stale-1")
}
let staleTransitions = try await stale.bridge.reconcile()
checkEqual("reconcile reports the archive", staleTransitions.map(\.kind), [.archived])
checkEqual("the silent thread is archived",
           try stale.store.thread(id: "sess-stale")?.archivedAt != nil, true)
let staleNotices = try stale.store.items(threadID: "sess-stale").filter { $0.kind == .notice }
checkEqual("the silent thread got exactly one notice", staleNotices.count, 1)
_ = try await stale.bridge.reconcile()
checkEqual("a second reconcile adds no second notice",
           try stale.store.items(threadID: "sess-stale").filter { $0.kind == .notice }.count, 1)

// 12. A thread left behind by a restart is archived by the first reconcile: no
//     session is live, so it is not connected.
let restart = BridgeHarness()
restart.store.seed(thread: osThread(id: "sess-orphan", projectID: "proj-general"))
let restartTransitions = try await restart.bridge.reconcile()
checkEqual("reconcile archives the orphaned external thread",
           restartTransitions.map(\.threadID), ["sess-orphan"])
checkEqual("the orphaned thread is archived",
           try restart.store.thread(id: "sess-orphan")?.archivedAt != nil, true)
check("the orphaned thread got a notice",
      try restart.store.items(threadID: "sess-orphan").contains { $0.kind == .notice })

// 13. The send path belongs to outside sessions only, and an unknown thread is
//     refused by name.
let other = BridgeHarness()
other.store.seed(thread: osThread(id: "local-thread", projectID: "proj-general",
                                  runtime: .opencode))
await expectOutsideSessionErrorAsync("a send to a VoiceFlow-run thread is not this path",
                                     code: "not_supported") {
    _ = try await other.bridge.send(threadID: "local-thread", text: "hi",
                                    commandID: "cmd-local-1")
}
await expectOutsideSessionErrorAsync("a send to an unknown thread is refused",
                                     code: "not_found") {
    _ = try await other.bridge.send(threadID: "no-such-thread", text: "hi",
                                    commandID: "cmd-missing-1")
}

// 14. Naming or reporting on a session the registry does not know is refused.
let unknown = BridgeHarness()
await expectOutsideSessionErrorAsync("naming an unknown session is refused",
                                     code: "not_found") {
    _ = try await unknown.bridge.setSessionName(sessionID: "ghost", name: "x",
                                               workingDirectory: nil)
}
await expectOutsideSessionErrorAsync("a report from an unknown session is refused",
                                     code: "runtime_unavailable") {
    _ = try await unknown.bridge.report(sessionID: "ghost", summary: "x", details: "",
                                        question: nil, timeoutSeconds: nil)
}

finishOutsideSessions("outside sessions: threads")
