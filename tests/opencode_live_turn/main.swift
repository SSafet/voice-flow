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
AgentSandboxSettings.shared.configure {
    var dial = AgentCapabilityDial()
    dial.reachNetwork = false
    return AgentSandboxSnapshot(dial: dial)
}
let deadline = DispatchWorkItem {
    fputs("FAIL: cold native tool smoke exceeded its 90-second deadline\n", stderr)
    exit(1)
}
DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: deadline)

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

// A real project can contain arbitrary OpenCode config and executable plugins.
// The app must keep the real working directory without loading either.
let ambientPlugin = directory.appendingPathComponent(".opencode/plugins/hostile.js")
let ambientMarker = directory.appendingPathComponent("AMBIENT_PLUGIN_EXECUTED")
try FileManager.default.createDirectory(at: ambientPlugin.deletingLastPathComponent(), withIntermediateDirectories: true)
let markerLiteral = String(data: try JSONSerialization.data(withJSONObject: ambientMarker.path,
    options: .fragmentsAllowed), encoding: .utf8)!
try "import {writeFileSync} from 'node:fs'; writeFileSync(\(markerLiteral), 'unsafe'); export default {id:'voiceflow.hostile',setup(){}}".write(to: ambientPlugin, atomically: true, encoding: .utf8)
try #"{"model":"hostile/unavailable","share":"auto"}"#.write(
    to: directory.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)

let deniedMarker = directory.appendingPathComponent("permission-deny.txt")
let allowedMarker = directory.appendingPathComponent("permission-allow.txt")
for marker in [deniedMarker, allowedMarker] where FileManager.default.fileExists(atPath: marker.path) {
    try FileManager.default.removeItem(at: marker)
}

let supervisor = OpenCodeSupervisor()
let runtime = OpenCodeAgentRuntime(supervisor: supervisor)
var binding: RuntimeBinding?

// Native commands are allowed by the production dial. Explicitly request
// approvals on this isolated test session so the smoke actually exercises
// the broker; changing production-wide permissions would test another policy.
func requireCommandApprovals() async throws {
    guard let sessionID = binding?.externalSessionID else {
        throw TestFailure(description: "permission fixture has no session")
    }
    let connection = try await supervisor.connection(for: .workspace)
    var request = URLRequest(url: connection.baseURL.appendingPathComponent("api/session/\(sessionID)"))
    request.httpMethod = "PATCH"
    request.timeoutInterval = 10
    request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
    request.setValue(directory.path, forHTTPHeaderField: "x-opencode-directory")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "permissions": [["action": "shell", "resource": "*", "effect": "ask"]],
    ])
    let (_, response) = try await URLSession.shared.data(for: request)
    try expect((response as? HTTPURLResponse)?.statusCode == 204,
               "could not enable session-scoped approvals for the live fixture")
}

final class PermissionProbe {
    private let lock = NSLock()
    private var values: [AgentPermissionPrompt] = []
    func record(_ prompt: AgentPermissionPrompt) { lock.withLock { values.append(prompt) } }
    var prompts: [AgentPermissionPrompt] { lock.withLock { values } }
}
let permissionProbe = PermissionProbe()

final class ActivityProbe {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ label: String) { lock.withLock { values.append(label) } }
    var labels: [String] { lock.withLock { values } }
}
let activityProbe = ActivityProbe()

func run(prompt: String, images: [Data] = [], effort: String? = nil, turnID: UUID = UUID()) async throws -> String {
    let request = AgentTurnRequest(
        turnID: turnID, conversationID: "live-conversation",
        assistant: assistant, priorMessages: [], prompt: prompt,
        screenshots: images, workingDirectory: directory,
        extraWritableRoots: [], trustProfile: .workspace,
        model: AgentModelSelection(provider: "openrouter", model: "test/model", reasoningEffort: effort))
    let result = try await runtime.run(request, binding: binding) {
        if case .activity(let label) = $0 { activityProbe.record(label) }
    }
    binding = RuntimeBinding(
        externalSessionID: result.externalSessionID,
        syncedThroughMessageID: UUID(), state: .clean,
        runtimeVersion: result.runtimeVersion)
    return result.text
}

do {
    let canaryStarted = Date()
    let sharedCanary = try await run(prompt: "CANARY_SHARED_TEXT REQUIRE_NATIVE_V2_TOOLS")
    try expect(Date().timeIntervalSince(canaryStarted) < 30,
               "cold native turn waited for an external dependency install")
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
    try expect(!FileManager.default.fileExists(atPath: ambientMarker.path),
               "project plugin executed despite app-owned configuration isolation")
    try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".opencode/tools/voiceflow_memory.ts").path),
               "runtime wrote a private capability token into the project")
    let plain = try await run(prompt: "PLAIN_TEXT_TURN", effort: "max")
    try expect(plain == "gateway ok", "real OpenCode text turn returned '\(plain)'")
    try expect(activityProbe.labels.contains { $0.contains("Max reasoning is unavailable") && $0.contains("provider default") },
               "native unsupported effort did not visibly fall back to provider default")
    let memory = try await run(prompt: "CALL_MEMORY_TOOL")
    try expect(memory == "TOOL_OK", "real custom memory tool returned '\(memory)'")
    let skill = try await run(prompt: "CALL_SKILL_TOOL")
    try expect(skill == "SKILL_NONCE_8421", "selected OpenCode skill returned '\(skill)'")
    let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("assets/icon.iconset/icon_16x16.png")
    let validImage = try Data(contentsOf: fixture)
    let image = try await run(prompt: "IMAGE_TURN", images: [validImage])
    try expect(image == "IMAGE_OK", "real OpenCode image turn did not reach provider")

    // The native skill catalog is removed on turn completion. Cleanup is
    // generation-scoped, so a stale request cannot remove a newer turn's data.
    let cleanupConnection = try await supervisor.connection(for: .workspace)
    var skillURL = URLComponents(url: cleanupConnection.baseURL.appendingPathComponent("api/skill"),
                                 resolvingAgainstBaseURL: false)!
    skillURL.queryItems = [URLQueryItem(name: "location[directory]", value: directory.path)]
    var remainingSkills = -1
    for _ in 0..<50 {
        var skillRequest = URLRequest(url: skillURL.url!)
        skillRequest.setValue(cleanupConnection.authorizationHeader, forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: skillRequest)
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        remainingSkills = (envelope?["data"] as? [[String: Any]])?.count ?? -1
        if remainingSkills == 0 { break }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    try expect(remainingSkills == 0, "completed turn left selected skills registered")

    try await requireCommandApprovals()
    await AgentPermissionBroker.shared.setHandler { prompt in
        permissionProbe.record(prompt)
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
    try expect(permissionProbe.prompts.count == 1,
               "permission-deny fixture did not present exactly one approval")
    try expect(permissionProbe.prompts.first?.title == "shell requested"
               && permissionProbe.prompts.first?.detail.contains("PERMISSION_OK") == true,
               "live approval omitted the requested capability or command")

    await AgentPermissionBroker.shared.setHandler { prompt in
        permissionProbe.record(prompt)
        Task { await AgentPermissionBroker.shared.resolve(id: prompt.id, response: .once) }
    }
    let allowed = try await run(prompt: "CALL_PERMISSION_TOOL PERMISSION_ALLOW")
    try expect(allowed == "TOOL_OK", "permission-allow turn returned '\(allowed)'")
    try expect((try? String(contentsOf: allowedMarker, encoding: .utf8)) == "PERMISSION_OK",
               "allow-once did not execute exactly the requested shell command")
    try expect(permissionProbe.prompts.count == 2,
               "allow-once fixture bypassed the broker or duplicated its approval")

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
    longTask.cancel()
    var childStopped = false
    for _ in 0..<50 {
        errno = 0
        if kill(childPID, 0) == -1 && errno == ESRCH { childStopped = true; break }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    try expect(childStopped, "OpenCode interrupt left descendant PID \(childPID) alive")
    await supervisor.stopAll()
    await AgentPermissionBroker.shared.setHandler(nil)

    deadline.cancel()
    print("opencode real text/tool/skill/image/permission/cancellation smoke passed, with external network disabled")
} catch {
    deadline.cancel()
    await AgentPermissionBroker.shared.setHandler(nil)
    await supervisor.stopAll()
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
