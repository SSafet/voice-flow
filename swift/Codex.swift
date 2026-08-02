import Foundation
import Darwin

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Codex subscription backend (ChatGPT OAuth via the Codex CLI)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// Runs assistant turns through `codex exec --json`, so they draw on the
// user's ChatGPT/Codex subscription quota instead of a metered API key.
// The CLI holds the OAuth credential (~/.codex/auth.json) and the
// conversation state; we keep only the thread id and resume it per turn.

let AgentBackendCodex = "codex"
let AgentBackendOpenCode = "opencode"
/// One-release decode/fallback identifier. New settings never write it.
let AgentBackendAPI = "api"

enum CodexBackendError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case usageLimit(String)
    case turnFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Codex CLI not found — install it (brew install codex) or switch the assistant backend to API key in Settings."
        case .notLoggedIn:
            return "Codex isn't signed in — run `codex login` in Terminal to connect your ChatGPT subscription."
        case .usageLimit(let message):
            return message.isEmpty
                ? "Codex subscription limit reached — it resets weekly. Add an API key in Settings for uninterrupted use."
                : message
        case .turnFailed(let message):
            return message
        }
    }
}

final class CodexExecBackend {
    struct TurnResult {
        let text: String
        let threadId: String?
    }

    private var process: Process?
    private var interrupted = false
    private let stateLock = NSLock()

    static func findBinary() -> String? {
        var candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/codex" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isLoggedIn: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json")
    }

    /// Codex needs its own home/config plus ordinary locale and network
    /// plumbing, but must not inherit provider keys or unrelated process
    /// authority from Voice Flow.
    static func sanitizedEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let allowlist = [
            "PATH", "HOME", "CODEX_HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
        ]
        var result: [String: String] = [:]
        for key in allowlist where source[key] != nil { result[key] = source[key] }
        return result
    }

    static func executionArguments(
        prompt: String, imagePaths: [String], resumeThread: String?,
        extraWritableRoots: [String]) -> [String] {
        // `exec` and `exec resume` diverge slightly in supported flags
        // (resume has no --sandbox/-C), so permissions go through -c. The
        // Assistant needs outbound access for user-requested integrations
        // such as the tickets CLI, while filesystem writes stay sandboxed.
        // mcp_servers={} neutralizes the user's ~/.codex MCP servers: they
        // slow every turn's startup and tempt the model into "contacting"
        // the user through tools instead of just answering the panel.
        var args = ["exec"]
        if let thread = resumeThread { args.append(contentsOf: ["resume", thread]) }
        args.append(contentsOf: ["--json", "--skip-git-repo-check",
                                 "-c", "sandbox_mode=\"workspace-write\"",
                                 "-c", "sandbox_workspace_write.network_access=true",
                                 "-c", "mcp_servers={}"])
        if !extraWritableRoots.isEmpty {
            // -c goes through TOML, and `resume` has no --add-dir flag, so the
            // extra roots ride the config key both paths accept.
            let toml = extraWritableRoots
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
                .joined(separator: ", ")
            args.append(contentsOf: ["-c", "sandbox_workspace_write.writable_roots=[\(toml)]"])
        }
        imagePaths.forEach { args.append(contentsOf: ["-i", $0]) }
        args.append(prompt)
        return args
    }

    func interrupt() {
        let active = stateLock.withLock { () -> Process? in
            interrupted = true
            return process
        }
        guard let active, active.isRunning else { return }
        let pid = active.processIdentifier
        let descendants = Self.descendants(of: pid)
        descendants.reversed().forEach { kill($0, SIGTERM) }
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            descendants.reversed().forEach { child in
                if kill(child, 0) == 0 { kill(child, SIGKILL) }
            }
            if active.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Run one turn. `onAgentText` fires per completed assistant message so
    /// the pill can grow while longer turns are still finishing.
    /// `workingDirectory` is the assistant's own folder (ticket VF-49): the
    /// workspace-write sandbox makes it her writable workplace, with
    /// `extraWritableRoots` for the few shared stores her duties touch.
    func run(prompt: String,
             images: [Data],
             resumeThread: String?,
             workingDirectory: URL? = nil,
             extraWritableRoots: [String] = [],
             onThreadStarted: @escaping (String) -> Void,
             onToolActivity: @escaping (String) -> Void,
             onAgentText: @escaping (String) -> Void) async throws -> TurnResult {
        guard let binary = Self.findBinary() else { throw CodexBackendError.notInstalled }
        guard Self.isLoggedIn else { throw CodexBackendError.notLoggedIn }

        var imagePaths: [String] = []
        for (index, data) in images.enumerated() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("vf-codex-\(UUID().uuidString)-\(index).jpg")
            try? data.write(to: url)
            imagePaths.append(url.path)
        }
        defer { imagePaths.forEach { try? FileManager.default.removeItem(atPath: $0) } }

        let args = Self.executionArguments(
            prompt: prompt, imagePaths: imagePaths, resumeThread: resumeThread,
            extraWritableRoots: extraWritableRoots)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = args
        proc.environment = Self.sanitizedEnvironment()
        proc.currentDirectoryURL = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        proc.standardInput = FileHandle.nullDevice

        stateLock.withLock { interrupted = false }
        var threadId: String?
        var replyParts: [String] = []
        var eventError: String?
        var lineBuffer = Data()
        let parseQueue = DispatchQueue(label: "vf.codex.parse")

        // Shared by the live readability handler and the post-exit flush.
        // Non-JSON lines (the CLI prints occasional notices) are skipped.
        let processChunk: (Data) -> Void = { chunk in
            parseQueue.sync {
                lineBuffer.append(chunk)
                while let newline = lineBuffer.firstIndex(of: 0x0A) {
                    let line = Data(lineBuffer.prefix(upTo: newline))
                    lineBuffer.removeSubrange(...newline)
                    guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let type = event["type"] as? String else { continue }
                    switch type {
                    case "thread.started":
                        if let id = event["thread_id"] as? String {
                            let isNew = threadId != id
                            threadId = id
                            if isNew { onThreadStarted(id) }
                        }
                    case "item.started", "item.updated":
                        if let item = event["item"] as? [String: Any],
                           let label = Self.activityLabel(for: item["type"] as? String ?? "") {
                            onToolActivity(label)
                        }
                    case "item.completed":
                        if let item = event["item"] as? [String: Any],
                           (item["type"] as? String) == "agent_message",
                           let text = item["text"] as? String, !text.isEmpty {
                            let piece = replyParts.isEmpty ? text : "\n\n" + text
                            replyParts.append(text)
                            onAgentText(piece)
                        }
                    case "error", "turn.failed":
                        eventError = (event["message"] as? String)
                            ?? ((event["error"] as? [String: Any])?["message"] as? String)
                    default:
                        break
                    }
                }
            }
        }

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { processChunk(chunk) }
        }

        stateLock.withLock { process = proc }
        defer {
            stateLock.withLock {
                if process === proc { process = nil }
            }
        }

        try proc.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in continuation.resume() }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        var remainder = stdout.fileHandleForReading.readDataToEndOfFile()
        remainder.append(0x0A)  // flush a final unterminated line
        processChunk(remainder)
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        if stateLock.withLock({ interrupted }) { throw CancellationError() }

        let (finalThread, text, failure) = parseQueue.sync { (threadId, replyParts.joined(separator: "\n\n"), eventError) }

        if proc.terminationStatus != 0 || (text.isEmpty && failure != nil) {
            let stderrText = String(data: errData.prefix(4_096), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let message = failure ?? (stderrText.isEmpty ? "Codex exited with status \(proc.terminationStatus)." : stderrText)
            throw Self.classify(message)
        }
        return TurnResult(text: text, threadId: finalThread)
    }

    private static func classify(_ message: String) -> CodexBackendError {
        let lower = message.lowercased()
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("quota") {
            return .usageLimit("Codex subscription limit reached — " + message)
        }
        if lower.contains("login") || lower.contains("logged in") || lower.contains("401")
            || lower.contains("unauthorized") || lower.contains("token") {
            return .notLoggedIn
        }
        return .turnFailed(message)
    }

    private static func activityLabel(for itemType: String) -> String? {
        switch itemType {
        case "command_execution": return "Running a command"
        case "web_search": return "Searching the web"
        case "mcp_tool_call": return "Using a tool"
        case "file_change": return "Editing files"
        case "reasoning": return "Thinking"
        default: return nil
        }
    }

    private static func descendants(of parent: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [parent]
        var seen: Set<pid_t> = [parent]
        while let current = queue.first {
            queue.removeFirst()
            var children = [pid_t](repeating: 0, count: 128)
            let bytes = proc_listchildpids(
                current, &children,
                Int32(children.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            let count = min(Int(bytes) / MemoryLayout<pid_t>.size, children.count)
            for child in children.prefix(count) where child > 0 && !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }
}

/// Injection seam for deterministic runtime contract tests. Production uses
/// `CodexExecBackend`; tests provide a JSONL-free fake with the same lifecycle.
protocol CodexExecuting: AnyObject {
    func interrupt()
    func run(prompt: String,
             images: [Data],
             resumeThread: String?,
             workingDirectory: URL?,
             extraWritableRoots: [String],
             onThreadStarted: @escaping (String) -> Void,
             onToolActivity: @escaping (String) -> Void,
             onAgentText: @escaping (String) -> Void) async throws -> CodexExecBackend.TurnResult
}

extension CodexExecBackend: CodexExecuting {}
