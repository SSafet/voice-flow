import Foundation

// The event normaliser (06 §3.7): each runtime's own stream becomes the
// thread protocol's items, so a runtime change never reaches a client (R4).
//
// The fixtures are the frames the three runtimes really send, in the spelling
// the shipping adapters already read (swift/CodexAppServer.swift,
// swift/ClaudeCode.swift, swift/OpenCodeHTTPClient.swift) and the method names
// of the pinned Codex app server. The assertions are on the contract's fields,
// never on a whole rendered event, because the engine — not the normaliser —
// owns ids, sequence numbers, where a turn ran and its timestamps.

func vflog(_ message: String) {}

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        failures += 1
    }
}

func line(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func feed(_ normaliser: RuntimeNormaliser, _ objects: [[String: Any]]) -> [RuntimeEvent] {
    objects.flatMap { normaliser.accept(line($0)) }
}

func drafts(_ events: [RuntimeEvent], _ kind: TPItemKind) -> [(RuntimeItemPhase, RuntimeItemDraft)] {
    events.compactMap {
        if case let .item(phase, draft) = $0, draft.kind == kind { return (phase, draft) }
        return nil
    }
}

func allDrafts(_ events: [RuntimeEvent]) -> [(RuntimeItemPhase, RuntimeItemDraft)] {
    events.compactMap {
        if case let .item(phase, draft) = $0 { return (phase, draft) }
        return nil
    }
}

func deltas(_ events: [RuntimeEvent], _ stream: TPDeltaStream) -> [(key: String, text: String)] {
    events.compactMap {
        if case let .delta(key, deltaStream, text) = $0, deltaStream == stream { return (key, text) }
        return nil
    }
}

func turnEnd(_ events: [RuntimeEvent]) -> (TPTurnStatus, TPStopReason?, TPTurnError?)? {
    for event in events {
        if case let .turnEnded(status, stop, error) = event { return (status, stop, error) }
    }
    return nil
}

func externalSession(_ events: [RuntimeEvent]) -> String? {
    for event in events {
        if case let .turnStarted(id) = event { return id }
    }
    return nil
}

func usage(_ events: [RuntimeEvent]) -> TPTurnUsage? {
    for event in events {
        if case let .usage(value) = event { return value }
    }
    return nil
}

// ━━ Codex ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

func codexFrame(_ method: String, _ params: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "method": method, "params": params.merging(["threadId": "th_abc"], uniquingKeysWith: { a, _ in a })]
}

let codex = CodexNormaliser()
var events = feed(codex, [
    codexFrame("turn/started", ["turnId": "turn_1"]),
    codexFrame("item/started", ["item": ["id": "it_1", "type": "commandExecution",
                                         "command": "pwd", "cwd": "/scratch/project"]]),
    codexFrame("item/commandExecution/outputDelta", ["itemId": "it_1", "delta": "/scratch/project\n"]),
    codexFrame("item/completed", ["item": ["id": "it_1", "type": "commandExecution",
                                           "command": "pwd", "status": "completed", "exitCode": 0,
                                           "aggregatedOutput": "/scratch/project\n"]]),
    codexFrame("item/reasoning/textDelta", ["delta": "weighing it"]),
    codexFrame("item/agentMessage/delta", ["delta": "The path is "]),
    codexFrame("item/agentMessage/delta", ["delta": "/scratch/project."]),
    codexFrame("thread/tokenUsage/updated", [
        "turnId": "turn_1",
        "tokenUsage": ["last": ["inputTokens": 1200, "outputTokens": 48],
                       "modelContextWindow": 272_000],
    ]),
    codexFrame("item/completed", ["item": ["id": "it_2", "type": "agentMessage",
                                           "text": "The path is /scratch/project."]]),
    codexFrame("turn/completed", ["turn": ["id": "turn_1", "status": "completed"]]),
])

expect(externalSession(events) == "th_abc", "codex: the external thread id is reported once")
let command = drafts(events, .toolCall)
expect(command.count == 2, "codex: the command is one item started and one completed")
expect(command.first?.0 == .started && command.first?.1.status == .inProgress,
       "codex: a command starts in progress")
expect(command.first?.1.key == "it_1", "codex: the item keeps the runtime's own id as its key")
expect(command.first?.1.toolCall?.kind == .execute, "codex: a command execution is an execute tool call")
expect(command.first?.1.toolCall?.name == "commandExecution",
       "codex: the tool's name is the runtime's own name for it")
expect(command.first?.1.toolCall?.title == "pwd", "codex: the title is the command that ran")
expect(command.last?.0 == .completed && command.last?.1.status == .completed,
       "codex: the command completes")
expect(command.last?.1.toolCall?.output?.first?.type == .terminal,
       "codex: a command's output is terminal output")
expect(command.last?.1.toolCall?.output?.first?.text == "/scratch/project\n",
       "codex: the output text is what the command printed")
expect(deltas(events, .output).map { $0.text } == ["/scratch/project\n"],
       "codex: output arrives as live deltas on the output stream")
expect(deltas(events, .output).allSatisfy { $0.key == "it_1" },
       "codex: an output delta names the item it belongs to")

let reasoning = drafts(events, .reasoning)
expect(reasoning.first?.0 == .started, "codex: thinking opens a reasoning item")
expect(deltas(events, .reasoning).map { $0.text } == ["weighing it"],
       "codex: thinking arrives on the reasoning stream")
let message = drafts(events, .assistantMessage)
expect(message.first?.0 == .started, "codex: the answer opens an assistant message at its first piece")
expect(deltas(events, .text).map { $0.text } == ["The path is ", "/scratch/project."],
       "codex: the answer arrives as live text deltas")
expect(message.last?.0 == .completed, "codex: the assistant message is completed")
expect(message.last?.1.text == "The path is /scratch/project.",
       "codex: the completed message carries the whole answer")
expect(message.count == 2, "codex: one assistant message, started once and completed once")

let codexUsage = usage(events)
expect(codexUsage?.inputTokens == 1200 && codexUsage?.outputTokens == 48,
       "codex: tokens are reported")
expect(codexUsage?.contextWindow == 272_000, "codex: with the model's context window")
expect(turnEnd(events)?.0 == .completed, "codex: the turn completed")
expect(turnEnd(events)?.1 == .endTurn, "codex: with the end-turn stop reason")

// The frames that are not about this turn are ignored, and an item type this
// version of Codex did not have becomes an ordinary tool call rather than
// vanishing.
let codexUnknown = CodexNormaliser()
let unknown = feed(codexUnknown, [
    codexFrame("thread/name/updated", ["name": "Something"]),
    codexFrame("item/started", ["item": ["id": "it_9", "type": "imageGeneration"]]),
    codexFrame("item/completed", ["item": ["id": "it_9", "type": "imageGeneration"]]),
])
expect(allDrafts(unknown).count == 2, "codex: an unknown notification is ignored")
expect(allDrafts(unknown).first?.1.toolCall?.kind == .other,
       "codex: an unknown item type is an 'other' tool call")
expect(allDrafts(unknown).first?.1.toolCall?.name == "imageGeneration",
       "codex: named after the type the runtime reported")

// Compaction is a notice, not a tool call.
let codexCompacted = CodexNormaliser()
let compacted = feed(codexCompacted, [
    codexFrame("item/completed", ["item": ["id": "it_c", "type": "contextCompaction"]]),
])
expect(drafts(compacted, .notice).first?.1.notice?.code == .compaction,
       "codex: compaction is a notice with the compaction code")

// A failed turn carries an error the person can act on.
let codexFailed = CodexNormaliser()
let failed = feed(codexFailed, [
    codexFrame("item/started", ["item": ["id": "it_1", "type": "commandExecution", "command": "pwd"]]),
    codexFrame("turn/completed", ["turn": ["id": "turn_1", "status": "failed",
                                           "error": ["message": "model provider refused"]]]),
])
expect(turnEnd(failed)?.0 == .failed, "codex: a failed turn ends failed")
expect(turnEnd(failed)?.2?.message == "model provider refused", "codex: with the runtime's message")
expect(turnEnd(failed)?.2?.code.isEmpty == false, "codex: and a code")
let leftOpen = allDrafts(failed).filter { $0.0 == .completed }
expect(leftOpen.count == 1 && leftOpen.first?.1.status == .failed,
       "codex: an item still running when the turn fails is completed as failed")

// The turn ends exactly once, whatever arrives afterwards.
let extra = codexFailed.accept(line(codexFrame("turn/completed", ["turn": ["status": "completed"]])))
expect(turnEnd(extra) == nil, "codex: a second end is ignored")
expect(codexFailed.finish(.completed(text: "late", usage: nil)).isEmpty,
       "codex: finishing an ended turn changes nothing")

// ━━ Claude Code ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let claude = ClaudeCodeNormaliser()
events = feed(claude, [
    ["type": "system", "subtype": "init", "session_id": "sess_1", "model": "claude-opus-5"],
    ["type": "stream_event", "event": ["type": "content_block_delta",
                                       "delta": ["type": "thinking_delta", "thinking": "planning"]]],
    ["type": "stream_event", "event": ["type": "content_block_start",
                                       "content_block": ["type": "tool_use", "id": "toolu_1",
                                                         "name": "Bash",
                                                         "input": ["command": "pwd"]]]],
    ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "toolu_1",
                                              "content": "/scratch/project"]]]],
    ["type": "stream_event", "event": ["type": "content_block_delta",
                                       "delta": ["type": "text_delta", "text": "Done."]]],
    ["type": "result", "subtype": "success", "is_error": false, "result": "Done.",
     "session_id": "sess_1", "total_cost_usd": 0.0123,
     "usage": ["input_tokens": 900, "output_tokens": 20]],
])

expect(externalSession(events) == "sess_1", "claude: the session id is reported once")
expect(deltas(events, .reasoning).map { $0.text } == ["planning"], "claude: thinking is reasoning")
let claudeTool = drafts(events, .toolCall)
expect(claudeTool.first?.1.key == "toolu_1", "claude: the tool call keeps the runtime's own id")
expect(claudeTool.first?.1.toolCall?.name == "Bash", "claude: named as the runtime names it")
expect(claudeTool.first?.1.toolCall?.kind == .execute, "claude: Bash is an execute tool call")
expect(claudeTool.first?.1.toolCall?.inputJSON?.contains("pwd") == true,
       "claude: the input travels as encoded JSON")
expect(claudeTool.last?.0 == .completed && claudeTool.last?.1.status == .completed,
       "claude: the tool result completes the call")
expect(claudeTool.last?.1.toolCall?.output?.first?.text == "/scratch/project",
       "claude: with the result as output")
expect(deltas(events, .text).map { $0.text } == ["Done."], "claude: the answer streams as text")
expect(drafts(events, .assistantMessage).last?.1.text == "Done.",
       "claude: the result line completes the assistant message")
expect(turnEnd(events)?.0 == .completed && turnEnd(events)?.1 == .endTurn,
       "claude: the turn completed")
let claudeUsage = usage(events)
expect(claudeUsage?.costMicros == 12_300, "claude: the cost is carried in millionths")
expect(claudeUsage?.costSettled == true, "claude: the final line's cost is settled")

// The Read tool reads, the Edit tool edits, the task list is a plan, and an
// unknown tool is an ordinary tool call.
let claudeKinds = ClaudeCodeNormaliser()
let kinds = feed(claudeKinds, [
    ["type": "stream_event", "event": ["type": "content_block_start",
                                       "content_block": ["type": "tool_use", "id": "t1", "name": "Read",
                                                         "input": ["file_path": "/a/b.txt"]]]],
    ["type": "stream_event", "event": ["type": "content_block_start",
                                       "content_block": ["type": "tool_use", "id": "t2", "name": "Edit",
                                                         "input": ["file_path": "/a/b.txt"]]]],
    ["type": "stream_event", "event": ["type": "content_block_start",
                                       "content_block": ["type": "tool_use", "id": "t3", "name": "WebSearch",
                                                         "input": ["query": "swift"]]]],
    ["type": "stream_event", "event": ["type": "content_block_start",
                                       "content_block": ["type": "tool_use", "id": "t4", "name": "Frobnicate",
                                                         "input": [:]]]],
    ["type": "stream_event", "event": ["type": "content_block_start",
                                       "content_block": ["type": "tool_use", "id": "t5", "name": "TodoWrite",
                                                         "input": ["todos": [["content": "Read the file",
                                                                              "status": "in_progress"],
                                                                             ["content": "Write it back",
                                                                              "status": "pending"]]]]]],
])
let kindByKey = Dictionary(uniqueKeysWithValues: drafts(kinds, .toolCall)
    .filter { $0.0 == .started }
    .compactMap { pair -> (String, TPToolKind)? in
        guard let kind = pair.1.toolCall?.kind else { return nil }
        return (pair.1.key, kind)
    })
expect(kindByKey["t1"] == .read, "claude: Read is a read")
expect(kindByKey["t2"] == .edit, "claude: Edit is an edit")
expect(kindByKey["t3"] == .search, "claude: WebSearch is a search")
expect(kindByKey["t4"] == .other, "claude: a tool nobody mapped is an 'other' tool call")
expect(drafts(kinds, .toolCall).contains { $0.1.key == "t1" && $0.1.toolCall?.locations?.first?.path == "/a/b.txt" },
       "claude: a file tool says which file it touched")
let plan = drafts(kinds, .plan)
expect(plan.count == 1 && plan.first?.0 == .started, "claude: the task list is one plan item")
expect(plan.first?.1.plan?.entries.count == 2, "claude: with an entry per task")
expect(plan.first?.1.plan?.entries.first?.status == .inProgress, "claude: carrying each task's state")
expect(plan.first?.1.plan?.entries.first?.content == "Read the file", "claude: and its text")
expect(!kindByKey.keys.contains("t5"), "claude: the task list is not also a tool call")
// A second task list replaces the first rather than adding a second plan.
let second = claudeKinds.accept(line(
    ["type": "stream_event", "event": ["type": "content_block_start",
                                       "content_block": ["type": "tool_use", "id": "t6", "name": "TodoWrite",
                                                         "input": ["todos": [["content": "Read the file",
                                                                              "status": "completed"]]]]]]))
expect(drafts(second, .plan).first?.0 == .updated, "claude: the plan is replaced as it changes")
expect(drafts(second, .plan).first?.1.key == plan.first?.1.key,
       "claude: and keeps the same item")

// A vendor helper agent: its work hangs under the call that started it, and
// carries the helper's name (06 §3.7).
let claudeHelper = ClaudeCodeNormaliser()
let helper = feed(claudeHelper, [
    ["type": "stream_event", "event": ["type": "content_block_start",
                                       "content_block": ["type": "tool_use", "id": "toolu_p", "name": "Task",
                                                         "input": ["subagent_type": "code-reviewer",
                                                                   "prompt": "review"]]]],
    ["type": "assistant", "parent_tool_use_id": "toolu_p",
     "message": ["content": [["type": "text", "text": "looks fine"]]]],
])
let helperItems = allDrafts(helper).filter { $0.1.parentKey != nil }
expect(!helperItems.isEmpty, "claude: the helper's items hang under the call that started it")
expect(helperItems.allSatisfy { $0.1.parentKey == "toolu_p" }, "claude: under that exact call")
expect(helperItems.allSatisfy { $0.1.agentName == "code-reviewer" },
       "claude: and carry the helper's name")
expect(allDrafts(helper).contains { $0.1.key == "toolu_p" && $0.1.parentKey == nil },
       "claude: the call itself has no parent")

// An error result fails the turn and names it.
let claudeFailed = ClaudeCodeNormaliser()
let claudeError = feed(claudeFailed, [
    ["type": "result", "subtype": "error_max_turns", "is_error": true, "session_id": "s"],
])
expect(turnEnd(claudeError)?.0 == .failed, "claude: an error result fails the turn")
expect(turnEnd(claudeError)?.2?.message.isEmpty == false, "claude: with a message")

// ━━ OpenCode ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

func openCodeFrame(_ type: String, _ properties: [String: Any]) -> [String: Any] {
    ["type": type, "properties": properties]
}

let openCode = OpenCodeNormaliser(sessionID: "ses_1")
events = feed(openCode, [
    openCodeFrame("message.updated", ["info": ["id": "msg_1", "sessionID": "ses_1", "role": "assistant"]]),
    openCodeFrame("message.part.updated", ["part": ["id": "prt_tool", "sessionID": "ses_1",
                                                    "messageID": "msg_1", "type": "tool", "tool": "bash",
                                                    "state": ["status": "running", "title": "pwd",
                                                              "input": ["command": "pwd"]]]]),
    openCodeFrame("message.part.updated", ["part": ["id": "prt_tool", "sessionID": "ses_1",
                                                    "messageID": "msg_1", "type": "tool", "tool": "bash",
                                                    "state": ["status": "completed", "title": "pwd",
                                                              "output": "/scratch/project"]]]),
    openCodeFrame("message.part.updated", ["part": ["id": "prt_text", "sessionID": "ses_1",
                                                    "messageID": "msg_1", "type": "text",
                                                    "text": "The path is "]]),
    openCodeFrame("message.part.updated", ["part": ["id": "prt_text", "sessionID": "ses_1",
                                                    "messageID": "msg_1", "type": "text",
                                                    "text": "The path is /scratch/project."]]),
])
expect(externalSession(events) == nil,
       "opencode: the session id is known before the stream, so it is not an event")
let openCodeTool = drafts(events, .toolCall)
expect(openCodeTool.first?.1.key == "prt_tool", "opencode: the tool call is keyed by its part")
expect(openCodeTool.first?.1.toolCall?.name == "bash", "opencode: named as OpenCode names it")
expect(openCodeTool.first?.1.toolCall?.kind == .execute, "opencode: bash is an execute tool call")
expect(openCodeTool.last?.0 == .completed, "opencode: the finished state completes the call")
expect(openCodeTool.last?.1.toolCall?.output?.first?.text == "/scratch/project",
       "opencode: with its output")
expect(deltas(events, .text).map { $0.text } == ["The path is ", "/scratch/project."],
       "opencode: a text snapshot becomes the piece that is new, never the whole text again")

// A part that belongs to another session is not this turn's.
let foreign = openCode.accept(line(openCodeFrame("message.part.updated",
    ["part": ["id": "prt_x", "sessionID": "ses_other", "messageID": "m", "type": "text", "text": "no"]])))
expect(foreign.isEmpty, "opencode: another session's parts are ignored")

// Permission events become approvals; the turn waits for a person.
let permission = openCode.accept(line(openCodeFrame("permission.asked",
    ["sessionID": "ses_1", "id": "perm_1", "permission": "bash", "patterns": ["rm *"]])))
var askedKey: String?
for event in permission {
    if case let .permissionAsked(key, title, detail) = event {
        askedKey = key
        expect(!title.isEmpty, "opencode: the approval has a title")
        expect(detail.contains("rm *"), "opencode: and says what would happen")
    }
}
expect(askedKey == "perm_1", "opencode: the approval keeps the runtime's own permission id")

// The turn's end does not come from the stream for OpenCode: it is the reply.
let ended = openCode.finish(.completed(text: "The path is /scratch/project.",
                                       usage: TPTurnUsage(contextTokens: 1200, contextWindow: 272_000,
                                                          costMicros: 400, costSettled: true,
                                                          inputTokens: 1200, outputTokens: 48)))
expect(drafts(ended, .assistantMessage).last?.1.text == "The path is /scratch/project.",
       "opencode: the reply completes the assistant message")
expect(turnEnd(ended)?.0 == .completed, "opencode: and ends the turn")
expect(usage(ended)?.inputTokens == 1200, "opencode: with the reply's usage")

// A stopped turn, and a runtime that dies mid-turn.
let stopped = OpenCodeNormaliser(sessionID: "ses_2")
_ = feed(stopped, [
    openCodeFrame("message.updated", ["info": ["id": "m", "sessionID": "ses_2", "role": "assistant"]]),
    openCodeFrame("message.part.updated", ["part": ["id": "p", "sessionID": "ses_2", "messageID": "m",
                                                    "type": "tool", "tool": "bash",
                                                    "state": ["status": "running", "title": "sleep 1000"]]]),
])
let afterStop = stopped.finish(.stopped)
expect(turnEnd(afterStop)?.0 == .interrupted, "a stopped turn ends interrupted")
expect(turnEnd(afterStop)?.1 == .cancelled, "with the cancelled stop reason")
expect(allDrafts(afterStop).contains { $0.0 == .completed && $0.1.status == .failed },
       "and the step that was running is closed, not left hanging")

let died = ClaudeCodeNormaliser()
_ = feed(died, [["type": "system", "subtype": "init", "session_id": "s"]])
let afterDeath = died.finish(.failed(code: "runtime_unavailable",
                                     message: "claude exited with status 1", retryable: true))
expect(turnEnd(afterDeath)?.0 == .failed, "a runtime that dies fails the turn")
expect(turnEnd(afterDeath)?.2?.code == "runtime_unavailable", "with the code the launcher uses")
expect(turnEnd(afterDeath)?.2?.retryable == true, "and whether trying again may work")

// ━━ Rules every normaliser keeps ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

// Long text is cut at the contract's limit and marked, and the whole text is
// kept for the engine to attach (01 §3.2, records.ts ITEM_TEXT_MAX_BYTES).
let huge = String(repeating: "a", count: 300 * 1024)
let cutting = ClaudeCodeNormaliser()
let cutEvents = feed(cutting, [
    ["type": "result", "subtype": "success", "is_error": false, "result": huge, "session_id": "s"],
])
let cutMessage = drafts(cutEvents, .assistantMessage).last?.1
expect(cutMessage?.truncated == true, "text over the limit is marked as cut")
expect((cutMessage?.text?.utf8.count ?? .max) <= 200 * 1024, "and is cut to the limit")
expect(cutMessage?.fullText?.count == huge.count, "the whole text stays for the engine to attach")

// Text is cleaned after it is cut: a lone surrogate would block the mirror.
let dirty = ClaudeCodeNormaliser()
let dirtyEvents = dirty.accept(Data(#"{"type":"result","subtype":"success","result":"a b","session_id":"s"}"#.utf8))
expect(drafts(dirtyEvents, .assistantMessage).last?.1.text?.contains("\u{0000}") == false,
       "a null character never reaches an event")

// A line that is not JSON, and one this runtime never sends, are ignored
// rather than guessed at.
expect(ClaudeCodeNormaliser().accept(Data("not json at all".utf8)).isEmpty,
       "an unreadable line produces nothing")
expect(CodexNormaliser().accept(Data("{}".utf8)).isEmpty, "an empty object produces nothing")

// A child run stamps every item it produces with the delegate's name and the
// task item it belongs to, which is how delegated work shows inside the
// turn's activity line (06 §3.7).
let child = CodexNormaliser(child: RuntimeChildContext(agentName: "Flora", parentKey: "task_1"))
let childEvents = feed(child, [
    codexFrame("item/started", ["item": ["id": "it_1", "type": "commandExecution", "command": "ls"]]),
    codexFrame("item/agentMessage/delta", ["delta": "done"]),
])
expect(!allDrafts(childEvents).isEmpty, "a child run produces items")
expect(allDrafts(childEvents).allSatisfy { $0.1.agentName == "Flora" },
       "every item of a child run carries the delegate's name")
expect(allDrafts(childEvents).allSatisfy { $0.1.parentKey == "task_1" },
       "and hangs under the task item the engine wrote")

if failures == 0 {
    print("runtime normaliser: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("not ok - \(failures) of \(checks) checks failed\n".utf8))
exit(1)
