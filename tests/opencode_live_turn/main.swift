import Foundation
import Darwin

func vflog(_ message: String) {}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(description: message) }
}

guard let upstreamText = ProcessInfo.processInfo.environment["VOICE_FLOW_TEST_UPSTREAM"],
      let upstream = URL(string: upstreamText) else {
    fputs("FAIL: VOICE_FLOW_TEST_UPSTREAM missing\n", stderr)
    exit(1)
}
ModelGatewayCredentials.shared.configure {
    ModelGatewayCredentialSnapshot(
        apiKey: "provider-secret", upstreamBaseURL: upstream,
        allowedModels: ["test/model"])
}

let directory = VoiceFlowPaths.shared.directory("assistants/live-open-code")
try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("memory"), withIntermediateDirectories: true)
try "2026-08-02: MEMORY_NONCE_7291".write(
    to: directory.appendingPathComponent("memory/core.md"), atomically: true, encoding: .utf8)
let skillDirectory = directory.appendingPathComponent("skills/test-skill")
try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
try "---\nname: test-skill\ndescription: Deterministic live test skill\n---\nReturn SKILL_NONCE_8421.".write(
    to: skillDirectory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
let assistant = AssistantDefinition(
    slug: "live-open-code", name: "Live", description: "", voice: nil,
    instructions: "", directory: directory, selectedSkills: ["test-skill"])
_ = try AgentSkillStore.project(for: assistant)

let deniedMarker = directory.appendingPathComponent("permission-deny.txt")
let allowedMarker = directory.appendingPathComponent("permission-allow.txt")
for marker in [deniedMarker, allowedMarker] where FileManager.default.fileExists(atPath: marker.path) {
    try FileManager.default.removeItem(at: marker)
}

let supervisor = OpenCodeSupervisor()
let runtime = OpenCodeAgentRuntime(supervisor: supervisor)
var binding: RuntimeBinding?

func run(prompt: String, images: [Data] = [], turnID: UUID = UUID()) async throws -> String {
    let request = AgentTurnRequest(
        turnID: turnID, conversationID: "live-conversation",
        assistant: assistant, priorMessages: [], prompt: prompt,
        screenshots: images, workingDirectory: directory,
        extraWritableRoots: [], trustProfile: .workspace,
        model: AgentModelSelection(provider: "openrouter", model: "test/model"))
    let result = try await runtime.run(request, binding: binding) { _ in }
    binding = RuntimeBinding(
        externalSessionID: result.externalSessionID,
        syncedThroughMessageID: UUID(), state: .clean,
        runtimeVersion: result.runtimeVersion)
    return result.text
}

do {
    let canaryStarted = Date()
    let sharedCanary = try await run(prompt: "CANARY_SHARED_TEXT")
    try expect(sharedCanary == "CANARY_SHARED_OK",
               "OpenCode shared canary returned '\(sharedCanary)'")
    if let reportPath = ProcessInfo.processInfo.environment["VOICE_FLOW_CANARY_OPENCODE_REPORT"] {
        let report: [String: Any] = [
            "runtime": "opencode", "task": "CANARY_SHARED_TEXT", "completed": true,
            "output": sharedCanary, "latency_seconds": Date().timeIntervalSince(canaryStarted),
            "errors": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: reportPath), options: [.atomic])
    }
    let plain = try await run(prompt: "PLAIN_TEXT_TURN")
    try expect(plain == "gateway ok", "real OpenCode text turn returned '\(plain)'")
    let memory = try await run(prompt: "CALL_MEMORY_TOOL")
    try expect(memory == "TOOL_OK", "real custom memory tool returned '\(memory)'")
    let skill = try await run(prompt: "CALL_SKILL_TOOL")
    try expect(skill == "SKILL_NONCE_8421", "selected OpenCode skill returned '\(skill)'")
    let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("assets/icon.iconset/icon_16x16.png")
    let validImage = try Data(contentsOf: fixture)
    let image = try await run(prompt: "IMAGE_TURN", images: [validImage])
    try expect(image == "IMAGE_OK", "real OpenCode image turn did not reach provider")

    await AgentPermissionBroker.shared.setHandler { prompt in
        Task { await AgentPermissionBroker.shared.resolve(id: prompt.id, response: .reject) }
    }
    do {
        _ = try await run(prompt: "CALL_PERMISSION_TOOL PERMISSION_DENY")
        try expect(false, "permission-deny turn unexpectedly returned a final")
    } catch let failure as AgentRuntimeFailure {
        try expect(failure.code == "opencode_permission_rejected" && !failure.retryable,
                   "permission rejection was not a typed non-retryable failure")
    }
    try expect(!FileManager.default.fileExists(atPath: deniedMarker.path),
               "rejected OpenCode permission executed its shell command")

    await AgentPermissionBroker.shared.setHandler { prompt in
        Task { await AgentPermissionBroker.shared.resolve(id: prompt.id, response: .once) }
    }
    let allowed = try await run(prompt: "CALL_PERMISSION_TOOL PERMISSION_ALLOW")
    try expect(allowed == "TOOL_OK", "permission-allow turn returned '\(allowed)'")
    try expect((try? String(contentsOf: allowedMarker, encoding: .utf8)) == "PERMISSION_OK",
               "allow-once did not execute exactly the requested shell command")

    let longPIDFile = directory.appendingPathComponent("long-child.pid")
    if FileManager.default.fileExists(atPath: longPIDFile.path) {
        try FileManager.default.removeItem(at: longPIDFile)
    }
    let longTurnID = UUID()
    let longTask = Task {
        try await run(prompt: "CALL_LONG_CHILD", turnID: longTurnID)
    }
    let childDeadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: longPIDFile.path), Date() < childDeadline {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let childPIDText = try String(contentsOf: longPIDFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let childPID = Int32(childPIDText), childPID > 1 else {
        throw TestFailure(description: "long-child probe did not expose a valid PID")
    }
    await runtime.cancel(turnID: longTurnID)
    await supervisor.stopAll()
    longTask.cancel()
    try await Task.sleep(nanoseconds: 300_000_000)
    errno = 0
    try expect(kill(childPID, 0) == -1 && errno == ESRCH,
               "OpenCode cancellation left descendant PID \(childPID) alive")
    await AgentPermissionBroker.shared.setHandler(nil)

    print("opencode real text/tool/skill/image/permission/cancellation smoke passed")
} catch {
    await AgentPermissionBroker.shared.setHandler(nil)
    await supervisor.stopAll()
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
