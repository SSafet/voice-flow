import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure(description: message) }
}

guard let binary = CodexExecBackend.findBinary() else {
    throw TestFailure(description: "installed Codex CLI was not discovered")
}
try expect(FileManager.default.isExecutableFile(atPath: binary),
           "discovered Codex path is not executable")
try expect(CodexExecBackend.isLoggedIn, "Codex CLI is not authenticated")

let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICE_FLOW_CONFIG_ROOT"]!)
let workspace = root.appendingPathComponent("codex-live-workspace")
try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
let backend = CodexExecBackend()

func run(_ prompt: String, images: [Data] = [], resume: String? = nil) async throws
    -> CodexExecBackend.TurnResult {
    try await backend.run(
        prompt: prompt, images: images, resumeThread: resume,
        workingDirectory: workspace, extraWritableRoots: [],
        onThreadStarted: { _ in }, onToolActivity: { _ in }, onAgentText: { _ in })
}

let canaryStarted = Date()
let sharedCanary = try await run(
    "CANARY_SHARED_TEXT. Reply with exactly CANARY_SHARED_OK and no punctuation or explanation.")
try expect(sharedCanary.text.trimmingCharacters(in: .whitespacesAndNewlines) == "CANARY_SHARED_OK",
           "Codex shared canary changed: \(sharedCanary.text)")
if let reportPath = ProcessInfo.processInfo.environment["VOICE_FLOW_CANARY_CODEX_REPORT"] {
    let report: [String: Any] = [
        "runtime": "codex", "task": "CANARY_SHARED_TEXT", "completed": true,
        "output": sharedCanary.text.trimmingCharacters(in: .whitespacesAndNewlines),
        "latency_seconds": Date().timeIntervalSince(canaryStarted), "errors": 0,
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try data.write(to: URL(fileURLWithPath: reportPath), options: [.atomic])
}

let first = try await run(
    "Reply with exactly CODEX_LIVE_NONCE_7319 and no punctuation or explanation.")
try expect(first.text.trimmingCharacters(in: .whitespacesAndNewlines) == "CODEX_LIVE_NONCE_7319",
           "Codex live text result changed: \(first.text)")
guard let thread = first.threadId, !thread.isEmpty else {
    throw TestFailure(description: "Codex live turn did not issue a thread id")
}

let resumed = try await run(
    "Reply with exactly CODEX_RESUME_NONCE_8842 and no punctuation or explanation.",
    resume: thread)
try expect(resumed.threadId == thread,
           "Codex resume changed thread identity")
try expect(resumed.text.trimmingCharacters(in: .whitespacesAndNewlines) == "CODEX_RESUME_NONCE_8842",
           "Codex live resume result changed: \(resumed.text)")

let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("assets/icon.iconset/icon_16x16.png")
let image = try Data(contentsOf: fixture)
let imaged = try await run(
    "An image is attached. Reply with exactly CODEX_IMAGE_NONCE_5527 and nothing else.",
    images: [image], resume: thread)
try expect(imaged.text.trimmingCharacters(in: .whitespacesAndNewlines) == "CODEX_IMAGE_NONCE_5527",
           "Codex live image result changed: \(imaged.text)")

let childPIDFile = workspace.appendingPathComponent("codex-child.pid")
let interrupted = Task {
    try await run(
        "Run exactly this shell command and wait for it: `sh -c 'echo $$ > codex-child.pid; sleep 120'`. "
        + "Do not use another command and do not reply until it exits.")
}
let childDeadline = Date().addingTimeInterval(30)
while !FileManager.default.fileExists(atPath: childPIDFile.path), Date() < childDeadline {
    try await Task.sleep(nanoseconds: 50_000_000)
}
guard let childPIDText = try? String(contentsOf: childPIDFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
      let childPID = Int32(childPIDText), childPID > 1 else {
    backend.interrupt()
    throw TestFailure(description: "Codex live child command did not start")
}
backend.interrupt()
do {
    _ = try await interrupted.value
    throw TestFailure(description: "Codex live interrupt unexpectedly completed normally")
} catch is CancellationError {
    // Expected typed cancellation.
}
try await Task.sleep(nanoseconds: 300_000_000)
errno = 0
try expect(kill(childPID, 0) == -1 && errno == ESRCH,
           "Codex interrupt left descendant PID \(childPID) alive")

print("codex real discovery/auth/new/resume/image/interrupt smoke passed")
