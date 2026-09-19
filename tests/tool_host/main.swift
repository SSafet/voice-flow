import Foundation

// The one tool host (06 §3.8): one registration point every tool reaches every
// caller through, the caller as {surface, threadId, turnId, permissionProfile},
// the two attributes branch 05 needs on every tool (remote and its class), the
// per-turn token the private MCP endpoint accepts only while that turn runs, the
// per-launch token and session match OpenCode's generated tools use, and one
// line in agent-security.jsonl for every authorised and every refused call.

// swift/Core.swift is deliberately not compiled into the suites, so this file
// carries the repository's usual logging stub.
func vflog(_ message: String) {}

var failures: [String] = []
var checks = 0

func check(_ what: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if !condition { failures.append(detail.isEmpty ? what : "\(what): \(detail)") }
}

func checkEqual<T: Equatable>(_ what: String, _ got: T, _ expected: T) {
    check(what, got == expected, "\(got) is not \(expected)")
}

func finish(_ suite: String) -> Never {
    if failures.isEmpty {
        print("\(suite): \(checks) checks, all pass")
        exit(0)
    }
    for failure in failures {
        FileHandle.standardError.write(Data("not ok - \(failure)\n".utf8))
    }
    FileHandle.standardError.write(Data("\(suite): \(failures.count) of \(checks) checks fail\n".utf8))
    exit(1)
}

func object(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
}

// A temp audit file, so the suite never writes the owner's agent-security.jsonl.
let auditRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vf-tool-host-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: auditRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: auditRoot) }
let auditURL = auditRoot.appendingPathComponent("agent-security.jsonl")
let audit = AgentSecurityAudit(url: auditURL)

var clock = Date(timeIntervalSince1970: 1_760_000_000)
let host = ToolHost(audit: audit, now: { clock })

func spec(_ name: String, remote: Bool, toolClass: ToolClass,
          outsideOnly: Bool = false) -> ToolSpec {
    ToolSpec(name: name, description: "\(name) does a thing",
             inputSchema: ["type": "object"], outputSchema: ["type": "object"],
             remote: remote, toolClass: toolClass, outsideOnly: outsideOnly)
}

var seenCallers: [ToolCaller] = []
var seenNames: [String] = []

// ── 1. One owner per tool name ──────────────────────────────────────────────
check(host.register(spec("captured_search", remote: true, toolClass: .observe)) { name, _, caller in
    seenNames.append(name); seenCallers.append(caller)
    return ToolResult.ok(#"{"ok":true,"tool":"captured_search"}"#)
}, "a tool registers")
check(host.register(spec("screen_draw", remote: true, toolClass: .present)) { _, _, _ in
    ToolResult.ok(#"{"ok":true}"#)
}, "a second tool registers")
check(host.register(spec("speak", remote: true, toolClass: .present)) { _, _, _ in
    ToolResult.ok(#"{"ok":true}"#)
}, "a third tool registers")
check(!host.register(spec("captured_search", remote: false, toolClass: .present)) { _, _, _ in
    ToolResult.fail("wrong", "the second registration must not win")
}, "a duplicate name is refused")
checkEqual("a refused duplicate does not replace the first", host.specs.count, 3)
checkEqual("the first registration keeps its class",
           host.specs.first(where: { $0.name == "captured_search" })?.toolClass, ToolClass.observe)

// The four outside-session tools, offered on the public endpoint only.
for name in ["set_session_name", "report_to_user", "check_messages", "wait_for_message"] {
    _ = host.register(spec(name, remote: false, toolClass: .present, outsideOnly: true)) { _, _, _ in
        ToolResult.ok(#"{"ok":true}"#)
    }
}

// ── 2. The list each way in sees ────────────────────────────────────────────
let deviceNames = Set(host.catalog(for: .device).map(\.name))
checkEqual("the device channel sees the remote tools", deviceNames,
           Set(["captured_search", "screen_draw", "speak"]))
let outsideNames = Set(host.catalog(for: .outside).map(\.name))
checkEqual("the public endpoint sees the four outside tools", outsideNames,
           Set(["set_session_name", "report_to_user", "check_messages", "wait_for_message"]))
let codexNames = Set(host.catalog(for: .codex).map(\.name))
checkEqual("a Codex turn sees the Mac tools and not the outside four", codexNames,
           Set(["captured_search", "screen_draw", "speak"]))
check(host.catalog(for: .opencode).contains(where: { $0.name == "screen_draw" }),
      "an OpenCode turn sees the screen tools")

// ── 3. Dispatch: the caller reaches the handler unchanged ───────────────────
let caller = ToolCaller(surface: .codex, threadId: "thread-7", turnId: "turn-9",
                        permissionProfile: "workspace")
let result = host.handle(name: "captured_search", arguments: ["text": "Disney"], caller: caller)
checkEqual("the handler's result is returned unchanged", object(result.json)["tool"] as? String,
           "captured_search")
check(!result.isError, "a successful call is not an error")
checkEqual("the caller reaches the handler", seenCallers.last, caller)
checkEqual("the tool name reaches the handler", seenNames.last, "captured_search")

// ── 4. Refusals by name ─────────────────────────────────────────────────────
let unknown = host.handle(name: "captured_teleport", arguments: [:], caller: caller)
check(unknown.isError, "an unknown tool is an error result")
checkEqual("an unknown tool is refused by its contract code",
           object(unknown.json)["code"] as? String, "not_found")
let notRemote = host.handle(name: "set_session_name",
                            arguments: [:],
                            caller: ToolCaller(surface: .device, threadId: nil, turnId: nil,
                                               permissionProfile: nil))
checkEqual("a tool that is not remote is refused over the device channel",
           object(notRemote.json)["code"] as? String, "not_supported")
let remoteOnDevice = host.handle(name: "captured_search", arguments: [:],
                                 caller: ToolCaller(surface: .device, threadId: "thread-3",
                                                    turnId: nil, permissionProfile: nil))
check(!remoteOnDevice.isError, "a remote tool is served over the device channel")

// ── 5. The audit file, with the thread id ───────────────────────────────────
let lines = (try? String(contentsOf: auditURL, encoding: .utf8))?
    .split(separator: "\n").map(String.init) ?? []
check(lines.count >= 2, "every call wrote a line to agent-security.jsonl")
func auditLine(containing needle: String) -> [String: Any]? {
    for line in lines where line.contains(needle) {
        if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
            return object
        }
    }
    return nil
}
let allowed = auditLine(containing: "captured_search")
checkEqual("the allowed call's audit line names the thread id",
           allowed?["conversationID"] as? String, "thread-7")
checkEqual("the allowed call's audit line names the tool", allowed?["action"] as? String,
           "captured_search")
checkEqual("the allowed call is recorded as an allow", allowed?["decision"] as? String, "allow")
checkEqual("the refused call's audit line names the tool",
           auditLine(containing: "captured_teleport")?["action"] as? String, "captured_teleport")
checkEqual("a refused call is recorded as a deny",
           auditLine(containing: "captured_teleport")?["decision"] as? String, "deny")

// ── 6. The per-turn token for the private MCP endpoint ──────────────────────
let token = host.openTurnToken(threadId: "thread-11", turnId: "turn-11", childRunId: nil,
                               surface: .codex, permissionProfile: "workspace", lifetime: 600)
checkEqual("the turn token is 32 random bytes as hex", token.count, 64)
let binding = host.resolveTurnToken(token)
checkEqual("the token names the thread", binding?.threadId, "thread-11")
checkEqual("the token names the turn", binding?.turnId, "turn-11")
checkEqual("the token names the surface", binding?.surface, ToolSurface.codex)
checkEqual("the token names the permission profile", binding?.permissionProfile, "workspace")
checkEqual("an unknown token resolves to nothing", host.resolveTurnToken("nope"), nil)
host.closeTurnToken(token)
checkEqual("a token after its turn ends resolves to nothing", host.resolveTurnToken(token), nil)

let childToken = host.openTurnToken(threadId: "thread-11", turnId: "turn-11",
                                    childRunId: "child-1", surface: .claude,
                                    permissionProfile: nil, lifetime: 600)
checkEqual("a child run's token names the child run",
           host.resolveTurnToken(childToken)?.childRunId, "child-1")
let expiring = host.openTurnToken(threadId: "thread-12", turnId: "turn-12", childRunId: nil,
                                  surface: .codex, permissionProfile: nil, lifetime: 60)
clock = clock.addingTimeInterval(61)
checkEqual("a token older than its lifetime resolves to nothing",
           host.resolveTurnToken(expiring), nil)

// ── 7. The per-launch token and the session match OpenCode uses ─────────────
host.setInternalToken("launch-token-1")
check(!host.authorizeInternal(token: "wrong", sessionId: "session-1"),
      "the wrong per-launch token is refused")
check(!host.authorizeInternal(token: "launch-token-1", sessionId: ""),
      "an empty session id is refused")
check(host.authorizeInternal(token: "launch-token-1", sessionId: "session-1"),
      "the right token and a session id are accepted")
host.setInternalToken(nil)
check(!host.authorizeInternal(token: "launch-token-1", sessionId: "session-1"),
      "after the token is cleared nothing is accepted")

// ── 8. Images travel with the result for the device channel ─────────────────
_ = host.register(spec("captured_get", remote: true, toolClass: .observe)) { _, _, caller in
    if caller.surface == .device {
        return ToolResult(json: #"{"ok":true}"#, isError: false,
                          images: [ToolImage(itemID: "frame:abc", data: Data([0xFF, 0xD8]),
                                             mimeType: "image/jpeg")])
    }
    return ToolResult(json: #"{"ok":true}"#, isError: false, images: [])
}
let withImage = host.handle(name: "captured_get", arguments: [:],
                            caller: ToolCaller(surface: .device, threadId: "thread-3",
                                               turnId: nil, permissionProfile: nil))
checkEqual("the device caller's image blocks are carried", withImage.images.first?.itemID,
           "frame:abc")
let withoutImage = host.handle(name: "captured_get", arguments: [:],
                               caller: ToolCaller(surface: .opencode, threadId: "thread-3",
                                                  turnId: nil, permissionProfile: nil))
checkEqual("a local caller gets no image blocks", withoutImage.images.count, 0)

finish("tool_host")
