import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func line(_ json: String) -> Data { Data(json.utf8) }

// ── Decoding the app-server's stream ──

expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","id":7,"result":{"thread":{"id":"thr_1"}}}"#))
       == .response(id: 7, error: nil), "a successful response must decode with its id")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","id":8,"error":{"code":-32600,"message":"no rollout found for thread id abc"}}"#))
       == .response(id: 8, error: "no rollout found for thread id abc"),
       "an error response must carry the server's message")
expect(CodexAppServerProtocol.result(of: line(#"{"id":7,"result":{"thread":{"id":"thr_1"}}}"#))?["thread"] != nil,
       "result(of:) must return the result object")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","method":"item/agentMessage/delta","params":{"threadId":"thr_1","turnId":"t1","itemId":"i1","delta":"po"}}"#))
       == .agentDelta(threadId: "thr_1", delta: "po"), "agent deltas must stream")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thr_1","item":{"type":"commandExecution","id":"c1"}}}"#))
       == .itemStarted(threadId: "thr_1", itemType: "commandExecution"), "item/started must carry the item type")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thr_1","item":{"type":"agentMessage","id":"m1","text":"pong"}}}"#))
       == .agentMessageCompleted(threadId: "thr_1", text: "pong"), "a completed agent message must carry its text")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thr_1","item":{"type":"userMessage","id":"u1"}}}"#))
       == .other(method: "item/completed"), "a completed user message is not a reply")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"t1","status":"completed"}}}"#))
       == .turnFinished(threadId: "thr_1", status: "completed", message: nil), "turn/completed must finish the turn")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"t1","status":"failed","error":{"message":"usage limit reached"}}}}"#))
       == .turnFinished(threadId: "thr_1", status: "failed", message: "usage limit reached"),
       "a failed turn must surface the server's message")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thr_1","turn":{"id":"t1","status":"interrupted"}}}"#))
       == .turnFinished(threadId: "thr_1", status: "interrupted", message: nil), "an interrupted turn must be reported as such")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","id":3,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr_1"}}"#))
       == .serverRequest(id: 3, method: "item/commandExecution/requestApproval"),
       "a server→client request must be recognised so it can be answered")
expect(CodexAppServerProtocol.decode(line(#"{"jsonrpc":"2.0","method":"thread/tokenUsage/updated","params":{}}"#))
       == .other(method: "thread/tokenUsage/updated"), "unknown notifications must not crash")
expect(CodexAppServerProtocol.decode(line("not json")) == nil, "garbage lines decode to nil")
let measured = AgentContextUsage(inputTokens: 80_000, outputTokens: 2_000, contextWindow: 128_000)!
expect(CodexAppServerProtocol.decode(line(#"{"method":"thread/tokenUsage/updated","params":{"threadId":"thr_1","turnId":"t1","tokenUsage":{"last":{"inputTokens":80000,"cachedInputTokens":60000,"outputTokens":2000,"totalTokens":82000},"total":{"totalTokens":9000000},"modelContextWindow":128000}}}"#))
       == .contextUsage(threadId: "thr_1", turnId: "t1", usage: measured),
       "context must use the last call, include cache exactly once, and preserve thread/turn identity")
expect(AgentContextUsage(inputTokens: -1) == nil
       && AgentContextUsage(inputTokens: Int.max, outputTokens: 1) == nil
       && AgentContextUsage.count(true) == nil, "invalid usage must not masquerade as a small context")

let oldUsage = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":80000,"output_tokens":2000},"total_token_usage":{"total_tokens":9000000},"model_context_window":128000}}}"#
let compacted = #"{"type":"compacted","payload":{}}"#
let newUsage = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":12000,"output_tokens":500},"model_context_window":128000}}}"#
expect(CodexRolloutUsage.decodeTail(Data((oldUsage + "\n" + compacted).utf8)) == nil,
       "pre-compaction usage must not survive without a new measurement")
expect(CodexRolloutUsage.decodeTail(Data((oldUsage + "\n" + compacted + "\n" + newUsage).utf8))?.tokens == 12_500,
       "post-compaction context must replace the old size rather than accumulate")
let usageRoot = FileManager.default.temporaryDirectory.appendingPathComponent("vf-usage-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: usageRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: usageRoot) }
let usageID = UUID().uuidString.lowercased()
let usageFile = usageRoot.appendingPathComponent("rollout-test-\(usageID).jsonl")
let metadata = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(usageID)\"}}\n"
try Data((metadata + String(repeating: " ", count: CodexRolloutUsage.maxReadBytes + 10) + "\n" + oldUsage).utf8).write(to: usageFile)
expect(CodexRolloutUsage.read(threadID: usageID, sessionsRoot: usageRoot) == measured,
       "bounded tail recovery must read this conversation's usage even from a large rollout")
try Data(("{\"type\":\"session_meta\",\"payload\":{\"id\":\"wrong\"}}\n" + oldUsage).utf8).write(to: usageFile)
expect(CodexRolloutUsage.read(threadID: usageID, sessionsRoot: usageRoot) == nil,
       "a cached path must be rechecked against session identity")

// ── Request shapes ──

let launch = CodexAppServerProtocol.launchArguments(extraWritableRoots: ["/tmp/a", "/tmp/b"])
expect(launch.first == "app-server", "the process must be the app-server")
expect(launch.contains("mcp_servers={}"), "the user's MCP servers must stay out of assistant turns")
expect(launch.contains("sandbox_workspace_write.network_access=true"), "network access mirrors the exec path")
expect(launch.contains("sandbox_workspace_write.writable_roots=[\"/tmp/a\", \"/tmp/b\"]"),
       "writable roots must be TOML-quoted: \(launch)")
expect(!CodexAppServerProtocol.launchArguments(extraWritableRoots: []).contains { $0.hasPrefix("sandbox_workspace_write.writable_roots") },
       "no roots means no writable_roots override")

// Backslashes and control characters are legal macOS filename characters.
// A backslash-n in a folder name must never become a different writable root.
let unusualRoots = ["/tmp/folder\\name", "/tmp/quote\"name", "/tmp/line\nfeed",
                    "/tmp/tab\tname", "/tmp/control\u{7f}", "/tmp/Български"]
let expectedRoots = #"sandbox_workspace_write.writable_roots=["/tmp/folder\\name", "/tmp/quote\"name", "/tmp/line\u000Afeed", "/tmp/tab\u0009name", "/tmp/control\u007F", "/tmp/Български"]"#
expect(CodexAppServerProtocol.launchArguments(extraWritableRoots: unusualRoots).contains(expectedRoots),
       "app-server writable-root names were altered or produced invalid TOML")
for resumeThread: String? in [nil, "thread-a"] {
    expect(CodexExecBackend.executionArguments(
        prompt: "task", imagePaths: [], resumeThread: resumeThread,
        extraWritableRoots: unusualRoots).contains(expectedRoots),
           "Codex exec writable-root names were altered or produced invalid TOML")
}

let start = CodexAppServerProtocol.threadParams(cwd: "/work", resumeThread: nil)
expect(start["approvalPolicy"] as? String == "never" && start["sandbox"] as? String == "workspace-write"
       && start["cwd"] as? String == "/work" && start["threadId"] == nil,
       "thread/start params changed: \(start)")
let resume = CodexAppServerProtocol.threadParams(cwd: "/work", resumeThread: "thr_9")
for thread in [nil, "existing"] as [String?] {
    let params = CodexAppServerProtocol.threadParams(cwd: "/work", resumeThread: thread,
        instructions: "PERSONA\nSKILLS\nGUIDANCE")
    expect(params["developerInstructions"] as? String == "PERSONA\nSKILLS\nGUIDANCE"
           && params["baseInstructions"] == nil,
           "start and resume must supply developer instructions without replacing Codex defaults")
}
expect(resume["threadId"] as? String == "thr_9", "thread/resume must name the thread")

let input = CodexAppServerProtocol.turnInput(prompt: "hello", imagePaths: ["/tmp/shot.jpg"])
expect(input.count == 2 && input[0]["type"] as? String == "text" && input[0]["text"] as? String == "hello",
       "the prompt must be the first text item")
expect(input[1]["type"] as? String == "localImage" && input[1]["path"] as? String == "/tmp/shot.jpg"
       && input[1]["localImage"] == nil,
       "images ride as v2 localImage items: {type: localImage, path} (the nested shape is rejected: missing field `url`)")
let turn = CodexAppServerProtocol.turnParams(threadId: "thr_1", prompt: "p", imagePaths: [], reasoningEffort: "low")
expect(turn["effort"] as? String == "low" && turn["threadId"] as? String == "thr_1", "turn params must carry effort and thread")
expect(CodexAppServerProtocol.turnParams(threadId: "t", prompt: "p", imagePaths: [], reasoningEffort: nil)["effort"] == nil,
       "an unset effort must not be sent")
expect(CodexAppServerProtocol.turnParams(threadId: "t", prompt: "p", imagePaths: [], model: "gpt-6-astra", reasoningEffort: nil)["model"] as? String == "gpt-6-astra"
       && CodexAppServerProtocol.turnParams(threadId: "t", prompt: "p", imagePaths: [], model: " ", reasoningEffort: nil)["model"] == nil,
       "a chosen model rides the turn; a blank one is not sent")

expect(CodexAppServerProtocol.activityLabel(for: "commandExecution") == "Running a command"
       && CodexAppServerProtocol.activityLabel(for: "userMessage") == nil,
       "activity labels changed")
expect(CodexAppServerProtocol.isThreadNotFound("no rollout found for thread id x")
       && !CodexAppServerProtocol.isThreadNotFound("usage limit reached"),
       "thread-not-found detection changed")

print("codex app-server protocol tests passed")
