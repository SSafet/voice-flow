import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let root = VoiceFlowPaths.shared.directory("assistants/tools-test")
try FileManager.default.createDirectory(
    at: root.appendingPathComponent("memory"), withIntermediateDirectories: true)
let assistant = AssistantDefinition(
    slug: "tools-test", name: "Tools", description: "", voice: nil,
    instructions: "", directory: root, selectedSkills: [])
let runID = UUID()
let runtimeSessionID = "session-a"
var screenshotCalls = 0
var computerOperations: [String] = []
var contextOperations: [String] = []
var overlayOperations: [String] = []
var userOperations: [String] = []
let environment = AgentToolEnvironment(
    computer: { args in
        screenshotCalls += 1
        computerOperations.append(args["action"] as? String ?? "")
        return AgentToolOutput(data: [
            "path": VoiceFlowPaths.shared.file("captures/shots/test.jpg").path,
            "width": 1440, "height": 900, "cursor": [4, 5],
        ])
    },
    context: { args in
        contextOperations.append(args["operation"] as? String ?? "")
        return AgentToolOutput(data: ["items": []])
    },
    overlay: { args in
        overlayOperations.append(args["operation"] as? String ?? "")
        return AgentToolOutput(data: ["id": "guide"])
    },
    user: { args in
        userOperations.append(args["operation"] as? String ?? "")
        return AgentToolOutput(data: ["delivered": true])
    })
let session = AgentToolSession(
    conversationID: "conversation-a", runID: runID,
    runtimeSessionID: runtimeSessionID, runtimeMessageID: "message-a",
    directory: root, assistant: assistant,
    policy: AgentPermissionPolicy(
        profile: .workspace, overrides: [.computerControl: .allow, .userAsk: .allow]),
    expiresAt: Date().addingTimeInterval(60), environment: environment)
AgentToolSessionRegistry.shared.register(session)
let authorized = try AgentToolSessionRegistry.shared.authorize(
    runtimeSessionID: runtimeSessionID, runtimeMessageID: "message-a", directory: root)
let shot = try await AgentToolDispatcher.execute(
    tool: "voiceflow_computer", arguments: ["action": "screenshot"], session: authorized)
expect(shot.data["width"] as? Int == 1440 && screenshotCalls == 1,
       "computer screenshot contract failed")
for arguments in [
    ["action": "cursor_position"],
    ["action": "left_click", "coordinate": [1, 2]],
    ["action": "right_click", "coordinate": [1, 2]],
    ["action": "double_click", "coordinate": [1, 2]],
    ["action": "mouse_move", "coordinate": [1, 2]],
    ["action": "drag", "start_coordinate": [1, 2], "coordinate": [3, 4]],
    ["action": "type", "text": "hello"],
    ["action": "key", "text": "ESC"],
    ["action": "scroll", "direction": "down", "amount": 3],
    ["action": "wait", "duration": 0.0],
] as [[String: Any]] {
    _ = try await AgentToolDispatcher.execute(
        tool: "voiceflow_computer", arguments: arguments, session: session)
}
expect(Set(computerOperations) == Set([
    "screenshot", "cursor_position", "left_click", "right_click", "double_click",
    "mouse_move", "drag", "type", "key", "scroll", "wait",
]), "computer operations were not all dispatched: \(computerOperations)")

for operation in ["latest_capture", "list_captures", "recent_dictations"] {
    _ = try await AgentToolDispatcher.execute(
        tool: "voiceflow_context", arguments: ["operation": operation], session: session)
}
expect(Set(contextOperations) == Set(["latest_capture", "list_captures", "recent_dictations"]),
       "context operations were not all dispatched")

for operation in ["show_guide", "update_guide", "show_panel", "annotate", "remove", "list"] {
    _ = try await AgentToolDispatcher.execute(
        tool: "voiceflow_overlay", arguments: ["operation": operation], session: session)
}
expect(Set(overlayOperations) == Set([
    "show_guide", "update_guide", "show_panel", "annotate", "remove", "list",
]), "overlay operations were not all dispatched")

for operation in ["report", "ask", "check", "wait"] {
    _ = try await AgentToolDispatcher.execute(
        tool: "voiceflow_user", arguments: ["operation": operation], session: session)
}
expect(Set(userOperations) == Set(["report", "ask", "check", "wait"]),
       "user operations were not all dispatched")

do {
    _ = try AgentToolSessionRegistry.shared.authorize(
        runtimeSessionID: runtimeSessionID, runtimeMessageID: "message-b", directory: root)
    expect(false, "cross-run message use succeeded")
} catch { expect((error as? AgentToolError) != nil, "wrong isolation error") }
do {
    _ = try AgentToolSessionRegistry.shared.authorize(
        runtimeSessionID: runtimeSessionID, runtimeMessageID: "message-a",
        directory: root, now: Date().addingTimeInterval(120))
    expect(false, "expired capability succeeded")
} catch { expect((error as? AgentToolError) != nil, "wrong expiry error") }

let memoryRead = try await AgentToolDispatcher.execute(
    tool: "voiceflow_memory", arguments: ["operation": "read", "kind": "core"], session: session)
let revision = memoryRead.data["revision"] as! String
let memoryWrite = try await AgentToolDispatcher.execute(
    tool: "voiceflow_memory",
    arguments: ["operation": "update", "kind": "core", "content": "2026-08-02: tool memory", "expected_revision": revision],
    session: session)
expect(memoryWrite.data["characters"] as? Int == 23, "memory tool update failed")
let ledgerRead = try await AgentToolDispatcher.execute(
    tool: "voiceflow_memory", arguments: ["operation": "read", "kind": "ledger"],
    session: session)
let ledgerRevision = ledgerRead.data["revision"] as! String
let ledgerWrite = try await AgentToolDispatcher.execute(
    tool: "voiceflow_memory", arguments: [
        "operation": "update", "kind": "ledger", "content": "evidence=passed",
        "expected_revision": ledgerRevision,
    ], session: session)
expect(ledgerWrite.data["characters"] as? Int == 15, "memory ledger update failed")
do {
    _ = try await AgentToolDispatcher.execute(
        tool: "voiceflow_context", arguments: ["operation": "invalid"], session: session)
    expect(false, "malformed context arguments succeeded")
} catch { expect((error as? AgentToolError) != nil, "wrong schema error") }
for (arguments, label) in [
    (["action": "launch_missiles"] as [String: Any], "unknown computer action"),
    (["action": "left_click", "coordinate": [1]] as [String: Any], "short coordinate"),
    (["action": "drag", "start_coordinate": [1, 2], "coordinate": [3, "four"]]
        as [String: Any], "non-numeric drag coordinate"),
    (["action": "scroll", "direction": "diagonal", "amount": 2]
        as [String: Any], "unknown scroll direction"),
    (["action": "scroll", "direction": "down", "amount": 31]
        as [String: Any], "oversized scroll amount"),
    (["action": "wait", "duration": 31] as [String: Any], "oversized wait"),
    (["action": "type", "text": 42] as [String: Any], "non-string typing"),
] {
    do {
        _ = try await AgentToolDispatcher.execute(
            tool: "voiceflow_computer", arguments: arguments, session: session)
        expect(false, "\(label) was accepted")
    } catch AgentToolError.invalidArguments { }
    catch { expect(false, "\(label) produced wrong error \(error)") }
}

let projection = AgentToolProjection(
    endpoint: URL(string: "http://127.0.0.1:1234/internal/tools")!, token: "token-canary")
let toolSources = projection.sources()
expect(Set(toolSources.map(\.0)) == Set(AgentToolDispatcher.names),
       "the generated tool sources must match the dispatcher's tools")
for (_, source) in toolSources {
    expect(source.contains("@opencode-ai/plugin") && source.contains("token-canary"),
           "a generated tool source is missing its plugin import or capability token")
}
let configHome = root.appendingPathComponent("open-config")
let firstWrite = try OpenCodeLaunch.writeToolFiles(
    endpoint: projection.endpoint, token: "token-canary", configHome: configHome)
expect(Set(firstWrite) == Set(AgentToolDispatcher.names.map { "\($0).ts" }),
       "writeToolFiles did not write every tool into the settings folder")
for name in firstWrite {
    let text = try String(contentsOf:
        OpenCodeLaunch.toolsDirectory(configHome: configHome).appendingPathComponent(name))
    expect(text.contains("token-canary"), "the first start's tools must carry its token")
}
let secondWrite = try OpenCodeLaunch.writeToolFiles(
    endpoint: projection.endpoint, token: "token-two", configHome: configHome)
expect(Set(secondWrite) == Set(AgentToolDispatcher.names.map { "\($0).ts" }),
       "a second start must leave exactly the same tool set")
for name in secondWrite {
    let text = try String(contentsOf:
        OpenCodeLaunch.toolsDirectory(configHome: configHome).appendingPathComponent(name))
    expect(text.contains("token-two") && !text.contains("token-canary"),
           "a second start must replace the previous token, never keep both")
}
expect(!FileManager.default.fileExists(
    atPath: assistant.directory.appendingPathComponent(".opencode").path),
    "nothing may be generated inside a persona folder")
expect(AgentToolOutput(data: ["value": String(repeating: "x", count: 30_000)])
    .json().contains("truncated"), "oversized result did not steer pagination")
print("agent tools tests passed")
