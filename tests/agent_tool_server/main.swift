import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let root = VoiceFlowPaths.shared.directory("assistants/tool-server")
try FileManager.default.createDirectory(
    at: root.appendingPathComponent("memory"), withIntermediateDirectories: true)
let assistant = AssistantDefinition(
    slug: "tool-server", name: "Tool Server", description: "", voice: nil,
    instructions: "", directory: root, selectedSkills: [])
let runID = UUID()
let session = AgentToolSession(
    conversationID: "conversation", runID: runID,
    runtimeSessionID: "runtime-session", runtimeMessageID: "runtime-message",
    directory: root, assistant: assistant,
    policy: AgentPermissionPolicy(profile: .workspace),
    expiresAt: Date().addingTimeInterval(60), environment: AgentToolEnvironment())
AgentToolSessionRegistry.shared.register(session)
let auditURL = VoiceFlowPaths.shared.file("tool-server-audit.jsonl")
let server = AgentToolServer(audit: AgentSecurityAudit(url: auditURL))
let connection = try server.start()

func call(endpoint: URL = connection.endpoint,
          token: String, messageID: String) async -> (Int?, String) {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = 3
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
        "tool": "voiceflow_memory",
        "arguments": ["operation": "read", "kind": "core"],
        "session_id": "runtime-session",
        "message_id": messageID,
        "directory": root.path,
    ])
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode,
                String(data: data, encoding: .utf8) ?? "")
    } catch { return (nil, "") }
}

let wrongToken = await call(token: "wrong", messageID: "runtime-message")
expect(wrongToken.0 == 401, "wrong process token was accepted")
let wrongMessage = await call(token: connection.token, messageID: "other-message")
expect(wrongMessage.0 == 403, "cross-run message replay was accepted")
let allowed = await call(token: connection.token, messageID: "runtime-message")
expect(allowed.0 == 200 && allowed.1.contains("revision"), "authorized tool call failed")
server.stop()
try? await Task.sleep(nanoseconds: 100_000_000)
let revoked = await call(token: connection.token, messageID: "runtime-message")
expect(revoked.0 == nil, "stopped tool server still accepted its token")
let rotated = try server.start()
expect(rotated.token != connection.token, "tool server restart reused its capability token")
let replay = await call(
    endpoint: rotated.endpoint, token: connection.token, messageID: "runtime-message")
expect(replay.0 == 401, "rotated tool server accepted the previous token")
let current = await call(
    endpoint: rotated.endpoint, token: rotated.token, messageID: "runtime-message")
expect(current.0 == 200, "rotated tool server rejected its current token")
server.stop()
let audit = try String(contentsOf: auditURL)
expect(audit.contains("deny") && audit.contains("allow"), "tool audit omitted decisions")
print("agent tool server live tests passed")
