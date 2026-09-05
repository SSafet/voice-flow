import Foundation
import Darwin

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Codex app-server backend — one long-lived `codex app-server` process
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  `codex exec` spawns a fresh process per turn and reports a reply only
//  once each agent message is complete. The app-server speaks JSON-RPC over
//  stdio, keeps threads warm, streams `item/agentMessage/delta` token by
//  token, and interrupts a turn with a request instead of a SIGTERM to a
//  process tree — the same integration T3 Code uses. Thread ids are the
//  same rollouts `codex exec` created, so existing conversations resume.
//
//  `CodexAppServerProtocol` is the pure half (line decoding, argument and
//  parameter shapes) and is unit-tested; the backend owns the process.

enum CodexAppServerMessage: Equatable {
    /// A reply to one of our requests. `error` is the server's message.
    case response(id: Int, error: String?)
    case agentDelta(threadId: String?, delta: String)
    case itemStarted(threadId: String?, itemType: String)
    case agentMessageCompleted(threadId: String?, text: String)
    /// `status` is completed | interrupted | failed; `message` rides a failure.
    case turnFinished(threadId: String?, status: String, message: String?)
    /// A server→client request we must answer (approvals). `id` is theirs.
    case serverRequest(id: Int, method: String)
    case other(method: String)
}

enum CodexAppServerProtocol {
    static let clientName = "voice-flow"

    /// One newline-delimited JSON line from the server. Non-JSON lines (the
    /// CLI prints notices on stderr, but stay defensive) decode to nil.
    static func decode(_ line: Data) -> CodexAppServerMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        let params = object["params"] as? [String: Any] ?? [:]
        let threadId = params["threadId"] as? String
        if let method = object["method"] as? String {
            if let id = object["id"] as? Int {
                return .serverRequest(id: id, method: method)
            }
            switch method {
            case "item/agentMessage/delta":
                return .agentDelta(threadId: threadId, delta: params["delta"] as? String ?? "")
            case "item/started":
                let item = params["item"] as? [String: Any] ?? [:]
                return .itemStarted(threadId: threadId, itemType: item["type"] as? String ?? "")
            case "item/completed":
                let item = params["item"] as? [String: Any] ?? [:]
                guard item["type"] as? String == "agentMessage" else { return .other(method: method) }
                return .agentMessageCompleted(threadId: threadId, text: item["text"] as? String ?? "")
            case "turn/completed", "turn/failed", "turn/interrupted":
                let turn = params["turn"] as? [String: Any] ?? [:]
                let status = turn["status"] as? String
                    ?? (method == "turn/failed" ? "failed"
                        : method == "turn/interrupted" ? "interrupted" : "completed")
                let error = (turn["error"] as? [String: Any])?["message"] as? String
                    ?? (params["error"] as? [String: Any])?["message"] as? String
                    ?? params["message"] as? String
                return .turnFinished(threadId: threadId, status: status, message: error)
            default:
                return .other(method: method)
            }
        }
        if let id = object["id"] as? Int {
            let error = (object["error"] as? [String: Any])?["message"] as? String
            return .response(id: id, error: error)
        }
        return nil
    }

    /// The whole result object of a response, for the few replies whose
    /// payload we read (thread and turn ids).
    static func result(of line: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        return object["result"] as? [String: Any]
    }

    /// Process arguments. The sandbox and network policy mirror the `exec`
    /// path exactly; writable roots are fixed for the process lifetime, so a
    /// request with a different set restarts it.
    static func launchArguments(extraWritableRoots: [String]) -> [String] {
        var args = [
            "app-server",
            "-c", "sandbox_mode=\"workspace-write\"",
            "-c", "sandbox_workspace_write.network_access=true",
            "-c", "mcp_servers={}",
        ]
        if !extraWritableRoots.isEmpty {
            let toml = extraWritableRoots
                .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
                .joined(separator: ", ")
            args.append(contentsOf: ["-c", "sandbox_workspace_write.writable_roots=[\(toml)]"])
        }
        return args
    }

    static func threadParams(cwd: String, resumeThread: String?) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": "never",
            "sandbox": "workspace-write",
        ]
        if let resumeThread { params["threadId"] = resumeThread }
        return params
    }

    static func turnInput(prompt: String, imagePaths: [String]) -> [[String: Any]] {
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        for path in imagePaths {
            // v2 `LocalImageUserInput`: {type: "localImage", path}. The nested
            // {type: "image", localImage: …} shape is rejected with "missing field `url`".
            input.append(["type": "localImage", "path": path])
        }
        return input
    }

    static func turnParams(threadId: String, prompt: String, imagePaths: [String],
                           model: String? = nil, reasoningEffort: String?) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": turnInput(prompt: prompt, imagePaths: imagePaths),
        ]
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            params["model"] = model
        }
        if let effort = reasoningEffort, !effort.isEmpty { params["effort"] = effort }
        return params
    }

    static func activityLabel(for itemType: String) -> String? {
        switch itemType {
        case "commandExecution": return "Running a command"
        case "webSearch": return "Searching the web"
        case "mcpToolCall": return "Using a tool"
        case "fileChange": return "Editing files"
        case "reasoning": return "Thinking"
        default: return nil
        }
    }

    /// "no rollout found for thread id …" and friends: the thread the
    /// binding remembers is gone, so the caller should start fresh.
    static func isThreadNotFound(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("no rollout found") || lower.contains("thread not found")
            || lower.contains("invalid thread id") || lower.contains("unknown thread")
    }
}

final class CodexAppServerBackend: CodexExecuting {
    private final class TurnState {
        let threadId: String
        var turnId: String?
        var interrupted = false
        var interruptWhenStarted = false
        var replyParts: [String] = []
        var streamedText = ""
        let onText: (String) -> Void
        let onActivity: (String) -> Void
        var completion: CheckedContinuation<(status: String, message: String?), Error>?
        init(threadId: String, onText: @escaping (String) -> Void,
             onActivity: @escaping (String) -> Void) {
            self.threadId = threadId
            self.onText = onText
            self.onActivity = onActivity
        }
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: Pipe?
    private var lineBuffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any]?, Error>] = [:]
    private var launchedRoots: [String]?
    /// Active turns by thread id: automations run two Codex jobs at once
    /// beside the assistant, all over this one process.
    private var turns: [String: TurnState] = [:]
    private var starting: Task<Void, Error>?

    static let handshakeTimeout: TimeInterval = 20

    // ── CodexExecuting ──

    func interrupt() { interrupt(threadId: nil) }

    /// End the process; the app is quitting or the owner is going away.
    func shutdown() {
        terminateProcess(lock.withLock { process })
    }

    /// Interrupt one thread's turn, or every turn when `threadId` is nil.
    /// A turn the server does not confirm interrupted within 3 s takes the
    /// process down — but only when no other turn is still being served.
    func interrupt(threadId: String?) {
        let (targets, active) = lock.withLock { () -> ([TurnState], Process?) in
            let all = Array(turns.values)
            let chosen = threadId.map { id in all.filter { $0.threadId == id } } ?? all
            for turn in chosen { turn.interrupted = true }
            return (chosen, process)
        }
        guard !targets.isEmpty else {
            if threadId == nil { terminateProcess(active) }
            return
        }
        for turn in targets {
            if let turnId = turn.turnId {
                notify("turn/interrupt", ["threadId": turn.threadId, "turnId": turnId])
            } else {
                turn.interruptWhenStarted = true
            }
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            let (wedged, live) = self.lock.withLock {
                (targets.filter { self.turns[$0.threadId] === $0 }.count, self.turns.count)
            }
            guard wedged > 0 else { return }
            if wedged == live {
                self.terminateProcess(active)
            } else {
                vflog("codex app-server: a turn ignored interrupt; leaving the process to its other turns")
            }
        }
    }

    func run(prompt: String,
             images: [Data],
             resumeThread: String?,
             workingDirectory: URL?,
             extraWritableRoots: [String],
             model: String?,
             reasoningEffort: String?,
             onThreadStarted: @escaping (String) -> Void,
             onToolActivity: @escaping (String) -> Void,
             onAgentText: @escaping (String) -> Void) async throws -> CodexExecBackend.TurnResult {
        guard let binary = CodexExecBackend.findBinary() else { throw CodexBackendError.notInstalled }
        guard CodexExecBackend.isLoggedIn else { throw CodexBackendError.notLoggedIn }

        try await startIfNeeded(binary: binary, roots: extraWritableRoots)

        var imagePaths: [String] = []
        for (index, data) in images.enumerated() {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("vf-codex-\(UUID().uuidString)-\(index).jpg")
            try? data.write(to: url)
            imagePaths.append(url.path)
        }
        defer { imagePaths.forEach { try? FileManager.default.removeItem(atPath: $0) } }

        let cwd = (workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser).path
        let threadId: String
        if let resumeThread {
            do {
                let result = try await request(
                    "thread/resume",
                    CodexAppServerProtocol.threadParams(cwd: cwd, resumeThread: resumeThread))
                threadId = Self.threadId(in: result) ?? resumeThread
            } catch let error as CodexBackendError {
                if case .turnFailed(let message) = error,
                   CodexAppServerProtocol.isThreadNotFound(message) {
                    throw CodexBackendError.threadNotFound(resumeThread)
                }
                throw error
            }
        } else {
            let result = try await request(
                "thread/start",
                CodexAppServerProtocol.threadParams(cwd: cwd, resumeThread: nil))
            guard let started = Self.threadId(in: result) else {
                throw CodexBackendError.turnFailed("codex app-server returned no thread id")
            }
            threadId = started
        }
        onThreadStarted(threadId)

        let state = TurnState(threadId: threadId, onText: onAgentText, onActivity: onToolActivity)
        lock.withLock { turns[threadId] = state }
        defer { lock.withLock { if turns[threadId] === state { turns.removeValue(forKey: threadId) } } }

        let finished: (status: String, message: String?) = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { state.completion = continuation }
                Task {
                    do {
                        let result = try await self.request(
                            "turn/start",
                            CodexAppServerProtocol.turnParams(
                                threadId: threadId, prompt: prompt, imagePaths: imagePaths,
                                model: model, reasoningEffort: reasoningEffort))
                        let turnId = (result?["turn"] as? [String: Any])?["id"] as? String
                        let interruptNow: Bool = self.lock.withLock {
                            state.turnId = turnId
                            return state.interruptWhenStarted || state.interrupted
                        }
                        if interruptNow, let turnId {
                            self.notify("turn/interrupt", ["threadId": threadId, "turnId": turnId])
                        }
                    } catch {
                        self.finishTurn(state, status: "failed", message: error.localizedDescription)
                    }
                }
            }
        }, onCancel: {
            interrupt(threadId: threadId)
        })

        if lock.withLock({ state.interrupted }) || finished.status == "interrupted" {
            throw CancellationError()
        }
        let text = lock.withLock { () -> String in
            state.replyParts.isEmpty ? state.streamedText : state.replyParts.joined(separator: "\n\n")
        }
        if finished.status == "failed" {
            throw Self.classify(finished.message ?? "Codex turn failed.")
        }
        return CodexExecBackend.TurnResult(text: text, threadId: threadId)
    }

    // ── Process lifecycle ──

    /// Concurrent turns share one start: the first caller spawns, the rest
    /// await the same task instead of racing a second process into being.
    /// A joined start may have been for other roots; the caller re-checks
    /// and starts again (or is told the server is busy) rather than running
    /// on a process whose writable roots are not its own.
    private func startIfNeeded(binary: String, roots: [String]) async throws {
        for _ in 0..<3 {
            let existing: Task<Void, Error>? = lock.withLock {
                let alive = process?.isRunning == true && launchedRoots == roots
                if alive { return nil }
                if let starting { return starting }
                let task = Task { try await self.ensureProcess(binary: binary, roots: roots) }
                starting = task
                return task
            }
            guard let existing else { return }
            do {
                try await existing.value
            } catch {
                lock.withLock { if starting == existing { starting = nil } }
                throw error
            }
            lock.withLock { if starting == existing { starting = nil } }
            if lock.withLock({ process?.isRunning == true && launchedRoots == roots }) { return }
        }
        throw CodexBackendError.appServerBusy
    }

    private func ensureProcess(binary: String, roots: [String]) async throws {
        let needsRestart = lock.withLock { () -> Bool in
            guard let process, process.isRunning else { return true }
            return launchedRoots != roots
        }
        guard needsRestart else { return }
        // Restarting with different roots must not cut a running turn.
        let busy = lock.withLock { !turns.isEmpty }
        if busy { throw CodexBackendError.appServerBusy }
        terminateProcess(lock.withLock { process })

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = CodexAppServerProtocol.launchArguments(extraWritableRoots: roots)
        proc.environment = CodexExecBackend.sanitizedEnvironment()
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let input = Pipe()
        let output = Pipe()
        proc.standardInput = input
        proc.standardOutput = output
        proc.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.processEnded(proc, reason: "codex app-server exited")
                return
            }
            self.consume(chunk)
        }
        proc.terminationHandler = { [weak self] ended in
            self?.processEnded(ended, reason: "codex app-server exited with status \(ended.terminationStatus)")
        }
        do {
            try proc.run()
        } catch {
            throw CodexBackendError.appServerUnavailable(error.localizedDescription)
        }
        lock.withLock {
            process = proc
            stdin = input.fileHandleForWriting
            stdout = output
            lineBuffer = Data()
            launchedRoots = roots
        }
        do {
            // The initialize request is not cancellable on its own: the
            // timeout ends the process, which fails every pending request.
            _ = try await withTimeout(Self.handshakeTimeout, onTimeout: { self.terminateProcess(proc) }) {
                try await self.request("initialize", [
                    "clientInfo": [
                        "name": CodexAppServerProtocol.clientName,
                        "title": "Voice Flow",
                        "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0",
                    ],
                ])
            }
            notify("initialized", [:])
            vflog("codex app-server: ready (roots: \(roots.count))")
        } catch {
            terminateProcess(proc)
            throw CodexBackendError.appServerUnavailable(error.localizedDescription)
        }
    }

    private func processEnded(_ proc: Process, reason: String) {
        let (continuations, active) = lock.withLock { () -> ([CheckedContinuation<[String: Any]?, Error>], [TurnState]) in
            guard process === proc || process == nil else { return ([], []) }
            process = nil
            stdin = nil
            stdout?.fileHandleForReading.readabilityHandler = nil
            stdout = nil
            launchedRoots = nil
            let waiting = Array(pending.values)
            pending.removeAll()
            let running = Array(turns.values)
            turns.removeAll()
            return (waiting, running)
        }
        for continuation in continuations {
            continuation.resume(throwing: CodexBackendError.turnFailed(reason))
        }
        for turn in active { finishTurn(turn, status: "failed", message: reason, alreadyCleared: true) }
    }

    private func terminateProcess(_ proc: Process?) {
        guard let proc, proc.isRunning else { return }
        let pid = proc.processIdentifier
        let descendants = ProcessTree.descendants(of: pid)
        descendants.reversed().forEach { kill($0, SIGTERM) }
        proc.terminate()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            descendants.reversed().forEach { child in
                if kill(child, 0) == 0 { kill(child, SIGKILL) }
            }
            if proc.isRunning { kill(pid, SIGKILL) }
        }
    }

    // ── JSON-RPC plumbing ──

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any]? {
        try await withCheckedThrowingContinuation { continuation in
            let id: Int = lock.withLock {
                let value = nextID
                nextID += 1
                pending[value] = continuation
                return value
            }
            guard send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
                lock.withLock { pending.removeValue(forKey: id) }
                continuation.resume(throwing: CodexBackendError.turnFailed("codex app-server is not running"))
                return
            }
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        _ = send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    @discardableResult
    private func send(_ object: [String: Any]) -> Bool {
        guard let handle = lock.withLock({ stdin }),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func consume(_ chunk: Data) {
        var lines: [Data] = []
        lock.withLock {
            lineBuffer.append(chunk)
            while let newline = lineBuffer.firstIndex(of: 0x0A) {
                lines.append(Data(lineBuffer.prefix(upTo: newline)))
                lineBuffer.removeSubrange(...newline)
            }
        }
        for line in lines where !line.isEmpty { handle(line) }
    }

    private func handle(_ line: Data) {
        guard let message = CodexAppServerProtocol.decode(line) else { return }
        switch message {
        case .response(let id, let error):
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            if let error {
                continuation?.resume(throwing: Self.classify(error))
            } else {
                continuation?.resume(returning: CodexAppServerProtocol.result(of: line))
            }
        case .agentDelta(let threadId, let delta):
            guard let turn = activeTurn(for: threadId), !delta.isEmpty else { return }
            lock.withLock { turn.streamedText += delta }
            turn.onText(delta)
        case .itemStarted(let threadId, let itemType):
            guard let turn = activeTurn(for: threadId),
                  let label = CodexAppServerProtocol.activityLabel(for: itemType) else { return }
            turn.onActivity(label)
        case .agentMessageCompleted(let threadId, let text):
            guard let turn = activeTurn(for: threadId), !text.isEmpty else { return }
            lock.withLock { turn.replyParts.append(text) }
        case .turnFinished(let threadId, let status, let errorMessage):
            guard let turn = activeTurn(for: threadId) else { return }
            finishTurn(turn, status: status, message: errorMessage)
        case .serverRequest(let id, let method):
            // approvalPolicy is "never", so this is unexpected; refusing keeps
            // the turn moving instead of hanging on an answer nobody sees.
            vflog("codex app-server: declining unexpected request \(method)")
            _ = send(["jsonrpc": "2.0", "id": id, "result": ["decision": "decline"]])
        case .other:
            break
        }
    }

    private func activeTurn(for threadId: String?) -> TurnState? {
        lock.withLock {
            guard let threadId else { return turns.count == 1 ? turns.values.first : nil }
            return turns[threadId]
        }
    }

    private func finishTurn(_ turn: TurnState, status: String, message: String?,
                            alreadyCleared: Bool = false) {
        let continuation = lock.withLock { () -> CheckedContinuation<(status: String, message: String?), Error>? in
            let value = turn.completion
            turn.completion = nil
            if !alreadyCleared, turns[turn.threadId] === turn { turns.removeValue(forKey: turn.threadId) }
            return value
        }
        continuation?.resume(returning: (status, message))
    }

    private static func threadId(in result: [String: Any]?) -> String? {
        (result?["thread"] as? [String: Any])?["id"] as? String
    }

    private static func classify(_ message: String) -> CodexBackendError {
        let lower = message.lowercased()
        if lower.contains("usage limit") || lower.contains("rate limit") || lower.contains("quota") {
            return .usageLimit("Codex subscription limit reached — " + message)
        }
        if lower.contains("login") || lower.contains("logged in") || lower.contains("401")
            || lower.contains("unauthorized") {
            return .notLoggedIn
        }
        return .turnFailed(message)
    }

    private func withTimeout<T>(_ seconds: TimeInterval, onTimeout: @escaping () -> Void,
                                _ body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                onTimeout()
                throw CodexBackendError.turnFailed("codex app-server did not answer initialize within \(Int(seconds)) s")
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

/// Descendants of a process, for terminating a runtime and everything it
/// spawned. Shared by the CLI runtimes.
enum ProcessTree {
    static func descendants(of parent: pid_t) -> [pid_t] {
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

    /// SIGTERM the tree (children first), then SIGKILL stragglers a second later.
    static func terminate(_ pid: pid_t) {
        let descendants = descendants(of: pid)
        descendants.reversed().forEach { kill($0, SIGTERM) }
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            descendants.reversed().forEach { child in
                if kill(child, 0) == 0 { kill(child, SIGKILL) }
            }
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }
}
