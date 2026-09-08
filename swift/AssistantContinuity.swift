import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  FLORA current-vs-new routing (ticket VF-54)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum LocalAssistantSessionAdapter {
    private static let prefix = "assistant:"

    static func id(for slug: String) -> String {
        prefix + slug
    }

    static func slug(from id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        let slug = String(id.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }
}

enum AssistantContinuityDecision: String, Codable, Equatable {
    case reuse
    case new
}

extension AssistantConversation {
    /// Whether an ambient wake turn ("FLORA, …") may continue this thread
    /// (ticket VF-61). An automation owns its conversation — every scheduled
    /// run resumes that same thread with the job's runtime and model — and a
    /// completed thread is one the user filed away. A dictation aimed at the
    /// assistant from anywhere on the machine belongs in neither, so the wake
    /// path opens a fresh conversation rather than appending to one of these.
    /// Typing into an open thread stays explicit and is unaffected.
    var acceptsWakeTurns: Bool {
        automationReferenceIDs.isEmpty && completedAt == nil
    }

    fileprivate var wakeIneligibilityReason: String? {
        if !automationReferenceIDs.isEmpty {
            return "the current conversation belongs to an automation"
        }
        if completedAt != nil { return "the current conversation is completed" }
        return nil
    }
}

struct AssistantContinuityOutcome: Equatable {
    let decision: AssistantContinuityDecision
    let confidence: Double
    let reason: String
    let usedFallback: Bool

    static func fallback(_ reason: String) -> AssistantContinuityOutcome {
        AssistantContinuityOutcome(
            decision: .reuse, confidence: 0, reason: reason, usedFallback: true)
    }
}

private struct AssistantContinuityResponse: Decodable {
    let decision: AssistantContinuityDecision
    let confidence: Double
    let reason: String
}

private enum AssistantContinuityError: LocalizedError {
    case codexUnavailable
    case timedOut
    case processFailed(String)
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .codexUnavailable: return "Codex CLI is unavailable or not signed in"
        case .timedOut: return "continuity classifier timed out"
        case .processFailed(let message): return message
        case .missingOutput: return "continuity classifier produced no output"
        }
    }
}

final class AssistantContinuityClassifier {
    typealias Runner = @Sendable (String) async throws -> String

    /// Resolved per run, not captured once: the user retunes this agent from
    /// the Agents panel and the very next wake must use the new setting.
    static var config: SystemAgentConfig { SystemAgentStore.shared.config(for: .continuity) }
    static let minimumNewConfidence = 0.65
    static let maxContextCharacters = 6_000
    static let maxIncomingCharacters = 4_000
    static let defaultTimeoutSeconds: TimeInterval = 15
    /// A wake that lands this soon after the current conversation's last
    /// message is a continuation: the model round trip (5–8 s, the whole
    /// wake latency) is only paid when the choice is real.
    static let defaultRecentReuseSeconds: TimeInterval = 180

    private let runner: Runner
    private let fallbackRunner: Runner?
    private let timeoutNanoseconds: UInt64
    private let recentReuseSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = AssistantContinuityClassifier.defaultTimeoutSeconds,
         recentReuseSeconds: TimeInterval = AssistantContinuityClassifier.defaultRecentReuseSeconds,
         runner: Runner? = nil,
         fallbackRunner: Runner? = nil) {
        self.timeoutNanoseconds = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
        self.recentReuseSeconds = recentReuseSeconds
        self.runner = runner ?? { prompt in
            try await Self.runCodex(prompt)
        }
        self.fallbackRunner = fallbackRunner ?? (runner == nil ? { prompt in
            try await ContinuityAPIFallback.run(prompt)
        } : nil)
    }

    func decide(current: AssistantConversation, incoming: String) async -> AssistantContinuityOutcome {
        // An ineligible thread is decided here, before the empty-draft shortcut:
        // an automation's conversation is still blank until its first run.
        if let reason = current.wakeIneligibilityReason {
            return AssistantContinuityOutcome(
                decision: .new, confidence: 1, reason: reason, usedFallback: false)
        }

        let relevant = current.messages.filter { $0.role != .note }
        guard !relevant.isEmpty || current.codexThreadId != nil else {
            return AssistantContinuityOutcome(
                decision: .reuse, confidence: 1,
                reason: "the current conversation is an empty draft", usedFallback: false)
        }

        if let last = relevant.last {
            let age = Date().timeIntervalSince(last.at)
            if age >= 0, age <= recentReuseSeconds {
                return AssistantContinuityOutcome(
                    decision: .reuse, confidence: 1,
                    reason: "the current conversation was active \(Int(age)) s ago", usedFallback: false)
            }
        }

        let prompt = Self.prompt(current: current, incoming: incoming)
        func decode(_ raw: String) throws -> AssistantContinuityOutcome {
            let data = Data(raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).utf8)
            let response = try JSONDecoder().decode(AssistantContinuityResponse.self, from: data)
            let confidence = min(1, max(0, response.confidence))
            guard response.decision != AssistantContinuityDecision.new
                    || confidence >= Self.minimumNewConfidence else {
                return .fallback("new was below the confidence threshold: \(confidence)")
            }
            return AssistantContinuityOutcome(
                decision: response.decision,
                confidence: confidence,
                reason: String(response.reason.prefix(240)),
                usedFallback: false)
        }
        do {
            return try decode(await runWithTimeout(prompt, runner: runner, timeout: timeoutNanoseconds))
        } catch {
            let primaryReason = Self.failureReason(error.localizedDescription)
            guard !Task.isCancelled, let fallbackRunner else { return .fallback(primaryReason) }
            vflog("continuity router: Codex failed; trying Assistant API: \(primaryReason)")
            do {
                let outcome = try decode(await runWithTimeout(prompt, runner: fallbackRunner, timeout: 10_000_000_000))
                return AssistantContinuityOutcome(decision: outcome.decision, confidence: outcome.confidence,
                    reason: "Assistant API after Codex failure (\(primaryReason)): \(outcome.reason)", usedFallback: outcome.usedFallback)
            } catch {
                return .fallback("Codex: \(primaryReason); API: \(Self.failureReason(error.localizedDescription))")
            }
        }
    }

    static func prompt(current: AssistantConversation, incoming: String) -> String {
        let messages = current.messages
            .filter { $0.role != .note }
            .suffix(6)
            .map { message -> String in
                let role = message.role == .user ? "USER" : "FLORA"
                let compact = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(role): \(String(compact.prefix(1_000)))"
            }
            .joined(separator: "\n")
        let context = String(("TITLE: \(current.title)\n" + messages).prefix(maxContextCharacters))
        let next = String(incoming.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(maxIncomingCharacters))
        // Only the leading brief is user-editable. The delimited blocks below
        // are the contract the decoder and the schema depend on, so they are
        // always appended here rather than living in the editable text.
        let brief = config.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        \(brief)

        <CURRENT_CONVERSATION>
        \(context)
        </CURRENT_CONVERSATION>

        <NEW_MESSAGE>
        \(next)
        </NEW_MESSAGE>
        """
    }

    private func runWithTimeout(_ prompt: String, runner: @escaping Runner, timeout: UInt64) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await runner(prompt) }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                throw AssistantContinuityError.timedOut
            }
            guard let first = try await group.next() else { throw AssistantContinuityError.missingOutput }
            group.cancelAll()
            return first
        }
    }

    static func failureReason(_ stderr: String) -> String {
        let lines = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Reading additional input") }
        let meaningful = lines.last { line in
            let lower = line.lowercased()
            return lower.contains("error") || lower.contains("limit") || lower.contains("failed")
                || lower.contains("unauthorized") || lower.contains("timed out")
        } ?? lines.last ?? "continuity classifier failed without diagnostics"
        return String(meaningful.suffix(500))
    }

    static let responseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "decision": ["type": "string", "enum": ["reuse", "new"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "reason": ["type": "string"],
        ],
        "required": ["decision", "confidence", "reason"],
        "additionalProperties": false,
    ]

    private static func findCodexBinary() -> String? {
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

    private static func runCodex(_ prompt: String) async throws -> String {
        guard let binary = findCodexBinary(),
              FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json") else {
            throw AssistantContinuityError.codexUnavailable
        }

        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("vf-continuity-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let schemaURL = directory.appendingPathComponent("schema.json")
        let outputURL = directory.appendingPathComponent("output.json")
        let errorURL = directory.appendingPathComponent("stderr.txt")
        try JSONSerialization.data(withJSONObject: responseSchema, options: [.prettyPrinted])
            .write(to: schemaURL, options: .atomic)
        fm.createFile(atPath: errorURL.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer { try? errorHandle.close() }

        let resolved = config
        vflog("continuity router: model=\(resolved.model) effort=\(resolved.effort ?? "provider default") brief=\(resolved.instructions.prefix(48))…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var arguments = [
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--skip-git-repo-check",
            "--sandbox", "read-only",
            "-m", resolved.model,
        ]
        if let effort = resolved.effort {
            arguments.append(contentsOf: ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
        arguments.append(contentsOf: [
            "-c", "mcp_servers={}",
            "--output-schema", schemaURL.path,
            "-o", outputURL.path,
            prompt,
        ])
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorHandle

        try Task.checkCancellation()
        let status: Int32 = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { completed in
                    continuation.resume(returning: completed.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            if process.isRunning { process.terminate() }
        })

        guard status == 0 else {
            let message = (try? String(contentsOf: errorURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AssistantContinuityError.processFailed(
                message.isEmpty ? "continuity classifier exited with status \(status)" : failureReason(message))
        }
        guard let output = try? String(contentsOf: outputURL, encoding: .utf8),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantContinuityError.missingOutput
        }
        return output
    }
}
