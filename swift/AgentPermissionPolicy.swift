import Foundation

struct AgentPermissionPrompt: Equatable {
    let id: String
    let conversationID: String
    let runID: UUID
    let title: String
    let detail: String
}

/// One app-owned approval queue serves both OpenCode's built-in permission
/// events and Voice Flow's private tools. Only allow-once and reject are
/// exposed: durable grants belong in the visible trust profile.
actor AgentPermissionBroker {
    static let shared = AgentPermissionBroker()
    typealias Handler = (AgentPermissionPrompt) -> Void

    private var handler: Handler?
    private var pending: [String: CheckedContinuation<AgentPermissionResponse, Never>] = [:]

    func setHandler(_ value: Handler?) {
        handler = value
        if value == nil { rejectAll() }
    }

    func request(_ prompt: AgentPermissionPrompt,
                 timeout: TimeInterval = 600) async -> AgentPermissionResponse {
        guard let handler else { return .reject }
        let key = prompt.id
        return await withCheckedContinuation { continuation in
            if let old = pending.removeValue(forKey: key) {
                old.resume(returning: .reject)
            }
            pending[key] = continuation
            DispatchQueue.main.async { handler(prompt) }
            Task { [weak self] in
                let nanos = UInt64(max(1, timeout) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                await self?.resolve(id: key, response: .reject)
            }
        }
    }

    func resolve(id: String, response: AgentPermissionResponse) {
        pending.removeValue(forKey: id)?.resume(returning: response)
    }

    func rejectAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        continuations.forEach { $0.resume(returning: .reject) }
    }
}

enum AgentPermissionDecision: String, Codable, Equatable {
    case allow
    case ask
    case deny
}

enum AgentCapabilityAction: String, Codable, CaseIterable {
    case computerObserve
    case computerControl
    case contextRead
    case overlayWrite
    case userReport
    case userAsk
    case memoryRead
    case memoryWrite
    case externalMCP
    case shell
    case editWorkspace
    case subagent
}

struct AgentPermissionPolicy: Equatable {
    let profile: AgentTrustProfile
    var overrides: [AgentCapabilityAction: AgentPermissionDecision] = [:]

    func decision(for action: AgentCapabilityAction) -> AgentPermissionDecision {
        if let override = overrides[action] { return override }
        switch profile {
        case .observe:
            switch action {
            case .computerObserve, .contextRead, .memoryRead: return .allow
            case .overlayWrite, .userReport, .userAsk: return .ask
            case .computerControl, .memoryWrite, .externalMCP, .shell,
                    .editWorkspace, .subagent: return .deny
            }
        case .workspace:
            switch action {
            case .computerObserve, .contextRead, .overlayWrite, .userReport,
                    .memoryRead, .memoryWrite, .editWorkspace: return .allow
            case .computerControl, .userAsk, .externalMCP, .shell: return .ask
            case .subagent: return .deny
            }
        case .unattended:
            switch action {
            case .computerObserve, .contextRead, .overlayWrite, .userReport,
                    .memoryRead, .memoryWrite: return .allow
            case .externalMCP, .editWorkspace: return .ask
            case .computerControl, .userAsk, .shell, .subagent: return .deny
            }
        }
    }

    /// Pinned OpenCode v1 permissions. The broad deny comes first because the
    /// last matching rule wins. Voice Flow tools are individually admitted by
    /// the private endpoint after this coarse runtime gate.
    func openCodeConfiguration(selectedSkills: [String],
                               readableExternalRoots: [URL]) -> [String: Any] {
        var skillRules: [String: String] = ["*": "deny"]
        for name in selectedSkills { skillRules[name] = "allow" }
        var externalRules: [String: String] = ["*": "deny"]
        for root in readableExternalRoots {
            externalRules[root.standardizedFileURL.path + "/**"] = "allow"
        }
        var result: [String: Any] = [
            "*": "deny",
            "voiceflow_*": "allow",
            "read": "allow",
            "skill": skillRules,
            "external_directory": externalRules,
        ]
        switch profile {
        case .observe:
            result["edit"] = "deny"
            result["bash"] = "deny"
        case .workspace:
            result["edit"] = "allow"
            result["bash"] = "ask"
        case .unattended:
            result["edit"] = "ask"
            result["bash"] = "deny"
        }
        result["task"] = "deny"
        result["question"] = "deny"
        result["webfetch"] = "deny"
        result["websearch"] = "deny"
        return result
    }
}

struct AgentMCPSelection: Codable, Equatable {
    let server: String
    let enabledTools: [String]
}

enum AgentMCPAllowlist {
    static func configuration(selections: [AgentMCPSelection],
                              knownServers: [String: [String: Any]]) -> [String: Any] {
        var mcp: [String: Any] = [:]
        var permissions: [String: String] = [:]
        for (name, raw) in knownServers {
            var server = raw
            guard let selection = selections.first(where: { $0.server == name }) else {
                server["enabled"] = false
                mcp[name] = server
                permissions["\(sanitize(name))_*" ] = "deny"
                continue
            }
            server["enabled"] = true
            mcp[name] = server
            permissions["\(sanitize(name))_*" ] = "deny"
            for tool in selection.enabledTools {
                permissions["\(sanitize(name))_\(sanitize(tool))"] = "allow"
            }
        }
        return ["mcp": mcp, "permission": permissions]
    }

    private static func sanitize(_ value: String) -> String {
        value.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
            .reduce(into: "", { $0.append($1) })
    }
}

struct AgentSecurityAuditEntry: Codable, Equatable {
    let time: Date
    let conversationID: String
    let runID: String
    let action: String
    let decision: AgentPermissionDecision
    let detail: String
}

final class AgentSecurityAudit {
    private let url: URL
    private let lock = NSLock()

    init(url: URL = VoiceFlowPaths.shared.file("agent-security.jsonl")) {
        self.url = url
    }

    func append(conversationID: String, runID: String, action: String,
                decision: AgentPermissionDecision, detail: String) {
        lock.withLock {
            let entry = AgentSecurityAuditEntry(
                time: Date(), conversationID: conversationID, runID: runID,
                action: action, decision: decision,
                detail: String(AgentSecretPolicy.redacted(detail).prefix(2_048)))
            guard let data = try? JSONEncoder.audit.encode(entry) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data + Data("\n".utf8))
        }
    }
}

private extension JSONEncoder {
    static var audit: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
