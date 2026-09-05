import Foundation
import Darwin

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Claude Code runtime (Claude subscription via the Claude Code CLI)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Runs assistant turns through `claude -p` with stream-json in and out —
//  the same headless contract the Claude Agent SDK (and T3 Code) drive.
//  The CLI holds the OAuth credential and the session transcript; Voice
//  Flow keeps the session id per conversation and resumes it per turn.
//  Containment is the CLI's own permission mode, mapped from the trust
//  profile, like Codex uses its own sandbox; only OpenCode runs under the
//  kernel profile.
//
//  `ClaudeCodeProtocol` is the pure half (line decoding, arguments, the
//  stdin message) and is unit-tested; the runtime owns the process.

enum ClaudeCodeStreamMessage: Equatable {
    case sessionStarted(sessionID: String, model: String?)
    case textDelta(String)
    case toolUse(name: String)
    /// A whole assistant text block, for CLIs that do not stream partials.
    case assistantText(String)
    case result(text: String, isError: Bool, sessionID: String?,
                inputTokens: Int?, outputTokens: Int?, costUSD: Double?)
    case other(type: String)
}

enum ClaudeCodeProtocol {
    static func decode(_ line: Data) -> ClaudeCodeStreamMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init",
                  let id = object["session_id"] as? String else { return .other(type: type) }
            return .sessionStarted(sessionID: id, model: object["model"] as? String)
        case "stream_event":
            let event = object["event"] as? [String: Any] ?? [:]
            switch event["type"] as? String {
            case "content_block_delta":
                let delta = event["delta"] as? [String: Any] ?? [:]
                guard delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String else { return .other(type: type) }
                return .textDelta(text)
            case "content_block_start":
                let block = event["content_block"] as? [String: Any] ?? [:]
                guard block["type"] as? String == "tool_use",
                      let name = block["name"] as? String else { return .other(type: type) }
                return .toolUse(name: name)
            default:
                return .other(type: type)
            }
        case "assistant":
            let message = object["message"] as? [String: Any] ?? [:]
            let blocks = message["content"] as? [[String: Any]] ?? []
            let text = blocks.compactMap { block -> String? in
                block["type"] as? String == "text" ? block["text"] as? String : nil
            }.joined()
            return .assistantText(text)
        case "result":
            let usage = object["usage"] as? [String: Any] ?? [:]
            let text = object["result"] as? String
                ?? (object["error"] as? String)
                ?? (object["subtype"] as? String).map { "Claude Code ended: \($0)" }
                ?? ""
            return .result(
                text: text,
                isError: object["is_error"] as? Bool ?? (object["subtype"] as? String != "success"),
                sessionID: object["session_id"] as? String,
                inputTokens: usage["input_tokens"] as? Int,
                outputTokens: usage["output_tokens"] as? Int,
                costUSD: object["total_cost_usd"] as? Double)
        default:
            return .other(type: type)
        }
    }

    /// Trust profile → the CLI's own permission mode. Observe reads only;
    /// workspace edits files without asking but confirms commands (which a
    /// headless turn cannot answer, so they are refused); unattended bypasses.
    static func permissionMode(for profile: AgentTrustProfile) -> String {
        switch profile {
        case .observe: return "plan"
        case .workspace: return "acceptEdits"
        case .unattended: return "bypassPermissions"
        }
    }

    /// The shared effort ladder, spelled the CLI's way. Claude Code has no
    /// "minimal"; it rounds to low.
    static func effortFlag(_ value: String?) -> String? {
        guard let normalized = AgentReasoningEffort.normalized(value) else { return nil }
        return normalized == "minimal" ? "low" : normalized
    }

    static func arguments(resumeSessionID: String?, newSessionID: String,
                          trustProfile: AgentTrustProfile, model: String?,
                          reasoningEffort: String?, extraDirectories: [String]) -> [String] {
        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-mode", permissionMode(for: trustProfile),
            // The user's own global settings and instructions apply; MCP
            // servers do not — the assistant answers in the panel, it does
            // not reach the user through tools.
            "--setting-sources", "user",
            "--strict-mcp-config",
        ]
        if trustProfile == .unattended { args.append("--dangerously-skip-permissions") }
        if let resumeSessionID {
            args.append(contentsOf: ["--resume", resumeSessionID])
        } else {
            args.append(contentsOf: ["--session-id", newSessionID])
        }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        if let effort = effortFlag(reasoningEffort) {
            args.append(contentsOf: ["--effort", effort])
        }
        if !extraDirectories.isEmpty {
            args.append("--add-dir")
            args.append(contentsOf: extraDirectories)
        }
        return args
    }

    /// One stream-json user message: the prompt plus screenshots as base64
    /// image blocks, newline-terminated for stdin.
    static func userMessage(text: String, jpegs: [Data]) -> Data {
        var content: [[String: Any]] = [["type": "text", "text": text]]
        for jpeg in jpegs {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": jpeg.base64EncodedString(),
                ],
            ])
        }
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": content],
        ]
        var data = (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
        data.append(0x0A)
        return data
    }

    static func activityLabel(forTool name: String) -> String {
        switch name {
        case "Bash", "BashOutput": return "Running a command"
        case "Read", "Grep", "Glob", "LS": return "Reading files"
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return "Editing files"
        case "WebSearch", "WebFetch": return "Searching the web"
        case "Task", "Agent": return "Delegating"
        default: return "Using \(name)"
        }
    }
}

enum ClaudeCodeError: LocalizedError {
    case notInstalled
    case notLoggedIn
    case turnFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Claude Code CLI not found — install it (npm i -g @anthropic-ai/claude-code) or pick another runtime."
        case .notLoggedIn:
            return "Claude Code isn't signed in — run `claude` in Terminal and use /login."
        case .turnFailed(let message):
            return message
        }
    }
}

final class ClaudeCodeAgentRuntime: AgentRuntime {
    let kind: AgentRuntimeKind = .claude
    let capabilities = AgentRuntimeCapabilities(
        images: true, nativeTools: true, skills: true,
        externalMCP: false, permissions: false)

    private let lock = NSLock()
    private var active: [UUID: Process] = [:]

    static func findBinary() -> String? {
        var candidates = [
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { String($0) + "/claude" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// `claude auth status` — a short read of the CLI's own credential state.
    static func isLoggedIn(binary: String) -> Bool? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["auth", "status"]
        proc.environment = sanitizedEnvironment()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(8)
        while proc.isRunning && Date() < deadline { usleep(50_000) }
        if proc.isRunning { proc.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["loggedIn"] as? Bool
    }

    /// The CLI keys its Keychain credential by `USER`; without it, it falls
    /// back to the stale `~/.claude/.credentials.json` and reports the OAuth
    /// session expired even right after a successful /login (measured).
    static func sanitizedEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment,
        userName: String = NSUserName()) -> [String: String] {
        let allowlist = [
            "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
            "CLAUDE_CONFIG_DIR",
        ]
        var result: [String: String] = [:]
        for key in allowlist where source[key] != nil { result[key] = source[key] }
        if result["USER"] == nil, !userName.isEmpty { result["USER"] = userName }
        if result["LOGNAME"] == nil, let user = result["USER"] { result["LOGNAME"] = user }
        return result
    }

    func status() async -> AgentRuntimeStatus {
        guard let binary = Self.findBinary() else {
            return AgentRuntimeStatus(health: .stopped, version: nil, detail: "Claude Code CLI is not installed.")
        }
        if Self.isLoggedIn(binary: binary) == false {
            return AgentRuntimeStatus(
                health: .degraded, version: nil,
                detail: "Claude Code is not signed in — run `claude` in Terminal and use /login.")
        }
        return AgentRuntimeStatus(health: .healthy, version: nil, detail: nil)
    }

    func run(_ request: AgentTurnRequest,
             binding: RuntimeBinding?,
             emit: @escaping (AgentRuntimeEvent) -> Void) async throws -> AgentTurnResult {
        guard let binary = Self.findBinary() else {
            let failure = AgentRuntimeFailure(
                code: "claude_not_installed",
                message: ClaudeCodeError.notInstalled.localizedDescription, retryable: false)
            emit(.failed(failure))
            throw failure
        }
        let newSessionID = UUID().uuidString.lowercased()
        let sessionID = binding?.externalSessionID ?? newSessionID
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ClaudeCodeProtocol.arguments(
            resumeSessionID: binding?.externalSessionID, newSessionID: newSessionID,
            trustProfile: request.trustProfile,
            model: request.model?.model,
            reasoningEffort: request.model?.reasoningEffort,
            extraDirectories: request.extraWritableRoots)
        proc.environment = Self.sanitizedEnvironment()
        proc.currentDirectoryURL = request.workingDirectory
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        final class Collector {
            let lock = NSLock()
            var buffer = Data()
            var streamed = ""
            var blocks: [String] = []
            var result: (text: String, isError: Bool, sessionID: String?,
                         inputTokens: Int?, outputTokens: Int?, costUSD: Double?)?
            var startedSession: String?
        }
        let collector = Collector()
        let handleLine: (Data) -> Void = { line in
            guard let message = ClaudeCodeProtocol.decode(line) else { return }
            switch message {
            case .sessionStarted(let id, let model):
                collector.lock.withLock { collector.startedSession = id }
                ClaudeModelCatalog.record(requested: request.model?.model, resolved: model)
            case .textDelta(let delta):
                collector.lock.withLock { collector.streamed += delta }
                emit(.textDelta(partID: "claude-agent", delta: delta))
            case .toolUse(let name):
                emit(.activity(ClaudeCodeProtocol.activityLabel(forTool: name)))
            case .assistantText(let text):
                collector.lock.withLock { collector.blocks.append(text) }
            case .result(let text, let isError, let id, let input, let output, let cost):
                collector.lock.withLock {
                    collector.result = (text, isError, id, input, output, cost)
                }
            case .other:
                break
            }
        }
        let drain: (Data) -> [Data] = { chunk in
            var lines: [Data] = []
            collector.lock.withLock {
                collector.buffer.append(chunk)
                while let newline = collector.buffer.firstIndex(of: 0x0A) {
                    lines.append(Data(collector.buffer.prefix(upTo: newline)))
                    collector.buffer.removeSubrange(...newline)
                }
            }
            return lines
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            drain(chunk).forEach(handleLine)
        }
        // stderr is drained as it comes: a chatty CLI blocked on a full
        // pipe would otherwise never finish the turn.
        let errorCollector = Collector()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            errorCollector.lock.withLock {
                if errorCollector.buffer.count < 64_000 { errorCollector.buffer.append(chunk) }
            }
        }

        lock.withLock { active[request.turnID] = proc }
        defer { lock.withLock { active.removeValue(forKey: request.turnID) } }
        // The handler is installed before launch: a CLI that exits at once
        // (signed out, bad flag) must still resume the wait below.
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do {
            try proc.run()
        } catch {
            let failure = AgentRuntimeFailure(
                code: "claude_launch_failed", message: error.localizedDescription, retryable: true)
            emit(.failed(failure))
            throw failure
        }
        emit(.started(externalSessionID: sessionID))
        let message = ClaudeCodeProtocol.userMessage(text: request.prompt, jpegs: request.screenshots)
        // main.swift ignores SIGPIPE process-wide, so a CLI that already
        // exited turns this into a failed write, not a dead app.
        try? stdin.fileHandleForWriting.write(contentsOf: message)
        try? stdin.fileHandleForWriting.close()

        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    exited.wait()
                    continuation.resume()
                }
            }
        }, onCancel: {
            ProcessTree.terminate(proc.processIdentifier)
        })
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        // Whatever is still in the pipe joins the partial line the handler
        // may have left, so a result line split across reads is not lost.
        var remainder = stdout.fileHandleForReading.readDataToEndOfFile()
        remainder.append(0x0A)
        drain(remainder).forEach(handleLine)
        let errorTail = stderr.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorCollector.lock.withLock { errorCollector.buffer + errorTail }
        let errorText = String(data: errorData.prefix(4_096), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if Task.isCancelled {
            emit(.interrupted)
            throw CancellationError()
        }
        let (result, streamed, blocks, started) = collector.lock.withLock {
            (collector.result, collector.streamed, collector.blocks, collector.startedSession)
        }
        guard let result else {
            let failure = AgentRuntimeFailure(
                code: "claude_no_result",
                message: errorText.isEmpty
                    ? "Claude Code exited with status \(proc.terminationStatus) without a result."
                    : errorText,
                retryable: true)
            emit(.failed(failure))
            throw failure
        }
        if result.isError {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            let message = lower.contains("authenticate") || lower.contains("not logged in") || lower.contains("oauth")
                ? ClaudeCodeError.notLoggedIn.localizedDescription + " (\(text))"
                : (text.isEmpty ? errorText : text)
            let failure = AgentRuntimeFailure(code: "claude_turn_failed", message: message, retryable: true)
            emit(.failed(failure))
            throw failure
        }
        let text = result.text.isEmpty ? (streamed.isEmpty ? blocks.joined(separator: "\n\n") : streamed) : result.text
        let usage = AgentUsage(
            inputTokens: result.inputTokens, outputTokens: result.outputTokens,
            costUSD: result.costUSD.map { Decimal($0) })
        emit(.usage(usage))
        emit(.completed(text: text))
        return AgentTurnResult(
            externalSessionID: result.sessionID ?? started ?? sessionID,
            runtimeVersion: nil, text: text, usage: usage)
    }

    func cancel(turnID: UUID) async {
        guard let proc = lock.withLock({ active[turnID] }), proc.isRunning else { return }
        ProcessTree.terminate(proc.processIdentifier)
    }
}


// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Claude Code models. The CLI takes an alias for the latest model of a
//  family ("fable", "opus", "sonnet", "haiku" — `claude --help`) or a full
//  id; which version an alias means is decided server-side, so nothing on
//  disk can list it. The app learns it the only honest way: every turn's
//  `system/init` event names the model that actually ran, and that
//  resolution is kept per requested alias in `claude-models.json` and shown
//  next to the alias in the picker ("Fable · claude-fable-5-1").
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum ClaudeModelCatalog {
    /// The CLI's documented aliases, in the order the picker shows them.
    static let aliases: [(alias: String, label: String)] = [
        ("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"),
    ]
    /// Key for "no model flag": the CLI's own default.
    static let defaultKey = ""

    private struct Store: Codable {
        var resolved: [String: String] = [:]
        var updatedAt: Date = Date()
    }
    private static let lock = NSLock()
    private static var cache: (modified: Date, store: Store)?
    private static var fileURL: URL { VoiceFlowPaths.shared.file("claude-models.json") }

    private static func load() -> Store {
        let path = fileURL.path
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            ?? .distantPast
        if let cached = lock.withLock({ cache }), cached.modified == modified { return cached.store }
        let store = (try? JSONDecoder().decode(Store.self, from: Data(contentsOf: fileURL))) ?? Store()
        lock.withLock { cache = (modified, store) }
        return store
    }

    /// The full model id the CLI ran for `requested` (an alias, a full id,
    /// or nil for its default), once a turn has taught it.
    static func resolved(for requested: String?) -> String? {
        let key = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultKey
        return load().resolved[key]
    }

    /// Called from the runtime's `system/init` event: remember what the
    /// CLI resolved `requested` to. A full id that resolves to itself is
    /// not worth a write.
    static func record(requested: String?, resolved model: String?) {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { return }
        let key = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultKey
        if key == model { return }
        var store = load()
        guard store.resolved[key] != model else { return }
        store.resolved[key] = model
        store.updatedAt = Date()
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL, options: .atomic)
            lock.withLock { cache = nil }
        }
    }

    /// Picker label for an alias or id: the alias name plus the version it
    /// last resolved to, when known.
    static func label(for value: String) -> String {
        let name = aliases.first { $0.alias == value }?.label ?? value
        if let id = resolved(for: value), id != value { return "\(name) · \(id)" }
        return name
    }

    /// The picker's choices after the leading default item.
    static func choices() -> [(value: String, label: String)] {
        aliases.map { ($0.alias, label(for: $0.alias)) }
    }
}
