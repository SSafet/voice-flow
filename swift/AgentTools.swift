import Foundation

enum AgentToolError: LocalizedError, Equatable {
    case unauthorized(String)
    case invalidArguments(String)
    case unavailable(String)
    case denied(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let value): return "Unauthorized tool request: \(value)"
        case .invalidArguments(let value): return "Invalid tool arguments: \(value)"
        case .unavailable(let value): return "Tool unavailable: \(value)"
        case .denied(let value): return "Tool denied: \(value)"
        case .unknownTool(let value): return "Unknown Voice Flow tool: \(value)"
        }
    }
}

struct AgentToolOutput {
    let data: [String: Any]

    func json(maxBytes: Int = 24_000) -> String {
        var value = data
        value["ok"] = true
        guard JSONSerialization.isValidJSONObject(value),
              let encoded = try? JSONSerialization.data(
                withJSONObject: value, options: [.sortedKeys]) else {
            return #"{"ok":false,"code":"serialization","message":"Tool result could not be encoded."}"#
        }
        guard encoded.count <= maxBytes else {
            let summary = [
                "ok": true,
                "truncated": true,
                "message": "Tool result exceeded \(maxBytes) bytes. Narrow the query or use pagination.",
            ] as [String: Any]
            let data = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            return String(data: data, encoding: .utf8)!
        }
        return String(data: encoded, encoding: .utf8)!
    }
}

struct AgentToolEnvironment {
    var computer: (([String: Any]) async throws -> AgentToolOutput)?
    var context: (([String: Any]) async throws -> AgentToolOutput)?
    var overlay: (([String: Any]) async throws -> AgentToolOutput)?
    var user: (([String: Any]) async throws -> AgentToolOutput)?
    var queue: (([String: Any]) async throws -> AgentToolOutput)? = nil
}

struct AgentToolSession {
    let conversationID: String
    let runID: UUID
    let runtimeSessionID: String
    let runtimeMessageID: String?
    let directory: URL
    let assistant: AssistantDefinition?
    let policy: AgentPermissionPolicy
    let expiresAt: Date
    let environment: AgentToolEnvironment
}

final class AgentToolSessionRegistry {
    static let shared = AgentToolSessionRegistry()
    private let lock = NSLock()
    private var sessions: [String: AgentToolSession] = [:]
    struct Prepared {
        let environment: AgentToolEnvironment
        let overrides: [AgentCapabilityAction: AgentPermissionDecision]
    }
    private var prepared: [UUID: Prepared] = [:]

    func prepare(turnID: UUID, environment: AgentToolEnvironment,
                 overrides: [AgentCapabilityAction: AgentPermissionDecision] = [:]) {
        lock.withLock { prepared[turnID] = Prepared(environment: environment, overrides: overrides) }
    }

    func takePrepared(turnID: UUID) -> Prepared {
        lock.withLock { prepared.removeValue(forKey: turnID) }
            ?? Prepared(environment: AgentToolEnvironment(), overrides: [:])
    }

    func register(_ session: AgentToolSession) {
        lock.withLock { sessions[session.runtimeSessionID] = session }
    }

    func remove(runtimeSessionID: String) {
        lock.withLock { sessions.removeValue(forKey: runtimeSessionID) }
    }

    func authorize(runtimeSessionID: String, runtimeMessageID: String,
                   directory: URL, now: Date = Date()) throws -> AgentToolSession {
        guard let session = lock.withLock({ sessions[runtimeSessionID] }) else {
            throw AgentToolError.unauthorized("unknown runtime session")
        }
        guard session.runtimeMessageID == nil || session.runtimeMessageID == runtimeMessageID else {
            throw AgentToolError.unauthorized("message does not match the active run")
        }
        guard now < session.expiresAt else {
            throw AgentToolError.unauthorized("run capability expired")
        }
        let expected = session.directory.standardizedFileURL.resolvingSymlinksInPath()
        let supplied = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard expected == supplied else {
            throw AgentToolError.unauthorized("directory does not match the session")
        }
        return session
    }
}

enum AgentToolDispatcher {
    static let names = [
        "voiceflow_computer", "voiceflow_context", "voiceflow_overlay",
        "voiceflow_user", "voiceflow_memory", "voiceflow_queue",
    ]

    static func execute(tool: String, arguments: [String: Any],
                        session: AgentToolSession) async throws -> AgentToolOutput {
        switch tool {
        case "voiceflow_computer":
            let action = try requiredEnum(
                "action", in: arguments,
                allowed: ["screenshot", "cursor_position", "left_click", "right_click",
                          "double_click", "mouse_move", "drag", "type", "key", "scroll", "wait"])
            switch action {
            case "left_click", "right_click", "double_click", "mouse_move":
                try requireCoordinate("coordinate", in: arguments)
            case "drag":
                try requireCoordinate("start_coordinate", in: arguments)
                try requireCoordinate("coordinate", in: arguments)
            case "type", "key":
                _ = try requiredString("text", in: arguments)
            case "scroll":
                _ = try requiredEnum(
                    "direction", in: arguments, allowed: ["up", "down", "left", "right"])
                if let amount = arguments["amount"] {
                    guard let number = amount as? NSNumber,
                          number.doubleValue.rounded() == number.doubleValue,
                          (1...30).contains(number.intValue) else {
                        throw AgentToolError.invalidArguments(
                            "`amount` must be an integer from 1 through 30")
                    }
                }
            case "wait":
                guard let duration = (arguments["duration"] as? NSNumber)?.doubleValue,
                      duration >= 0, duration <= 30 else {
                    throw AgentToolError.invalidArguments("`duration` must be a number from 0 through 30")
                }
            default: break
            }
            let capability: AgentCapabilityAction = action == "screenshot" || action == "cursor_position"
                ? .computerObserve : .computerControl
            try await require(session.policy.decision(for: capability), action: capability,
                              arguments: arguments, session: session)
            guard let handler = session.environment.computer else {
                throw AgentToolError.unavailable("computer bridge is not connected")
            }
            return try await handler(arguments)
        case "voiceflow_context":
            try await require(session.policy.decision(for: .contextRead), action: .contextRead,
                              arguments: arguments, session: session)
            _ = try requiredEnum("operation", in: arguments,
                                 allowed: ["latest_capture", "list_captures", "recent_dictations"])
            guard let handler = session.environment.context else {
                throw AgentToolError.unavailable("context bridge is not connected")
            }
            return try await handler(arguments)
        case "voiceflow_overlay":
            try await require(session.policy.decision(for: .overlayWrite), action: .overlayWrite,
                              arguments: arguments, session: session)
            _ = try requiredEnum("operation", in: arguments,
                                 allowed: ["show_guide", "update_guide", "show_panel", "annotate", "remove", "list"])
            guard let handler = session.environment.overlay else {
                throw AgentToolError.unavailable("overlay bridge is not connected")
            }
            return try await handler(arguments)
        case "voiceflow_user":
            let operation = try requiredEnum(
                "operation", in: arguments, allowed: ["report", "ask", "check", "wait"])
            let action: AgentCapabilityAction = (operation == "ask" || operation == "wait")
                ? .userAsk : .userReport
            try await require(session.policy.decision(for: action), action: action,
                              arguments: arguments, session: session)
            guard let handler = session.environment.user else {
                throw AgentToolError.unavailable("user bridge is not connected")
            }
            return try await handler(arguments)
        case "voiceflow_memory":
            guard let assistant = session.assistant else {
                throw AgentToolError.unavailable("this conversation has no folder assistant")
            }
            let operation = try requiredEnum("operation", in: arguments, allowed: ["read", "update"])
            let action: AgentCapabilityAction = operation == "read" ? .memoryRead : .memoryWrite
            try await require(session.policy.decision(for: action), action: action,
                              arguments: arguments, session: session)
            let kind = try requiredEnum("kind", in: arguments, allowed: ["core", "ledger"])
            let store = AgentMemoryStore(assistant: assistant)
            if operation == "read" {
                let document = try store.read(kind: kind)
                return AgentToolOutput(data: [
                    "kind": document.kind, "content": document.content,
                    "revision": document.revision, "clipped": document.clipped,
                ])
            }
            let content = try requiredString("content", in: arguments, allowEmpty: true)
            let revision = try requiredString("expected_revision", in: arguments)
            let document = try store.update(
                kind: kind, content: content, expectedRevision: revision)
            return AgentToolOutput(data: [
                "kind": document.kind, "revision": document.revision,
                "characters": document.content.count,
                "message": "Memory updated atomically.",
            ])
        case "voiceflow_queue":
            let operation = try requiredEnum(
                "operation", in: arguments, allowed: ["list", "add", "done", "remove"])
            let action: AgentCapabilityAction = operation == "list" ? .memoryRead : .memoryWrite
            try await require(session.policy.decision(for: action), action: action,
                              arguments: arguments, session: session)
            guard let handler = session.environment.queue else {
                throw AgentToolError.unavailable("queue bridge is not connected")
            }
            return try await handler(arguments)
        default:
            throw AgentToolError.unknownTool(tool)
        }
    }

    private static func require(_ decision: AgentPermissionDecision,
                                action: AgentCapabilityAction,
                                arguments: [String: Any],
                                session: AgentToolSession) async throws {
        switch decision {
        case .allow: return
        case .ask:
            let safeDetail = String(AgentSecretPolicy.redacted(
                arguments.keys.sorted().map { "\($0)=\(String(describing: arguments[$0]!))" }
                    .joined(separator: ", ")).prefix(2_048))
            let response = await AgentPermissionBroker.shared.request(AgentPermissionPrompt(
                id: "tool:\(session.runID.uuidString):\(action.rawValue):\(UUID().uuidString)",
                conversationID: session.conversationID, runID: session.runID,
                title: action.rawValue, detail: safeDetail))
            guard response == .once else {
                throw AgentToolError.denied("\(action.rawValue) was rejected")
            }
        case .deny:
            throw AgentToolError.denied("\(action.rawValue) is disabled by this trust profile")
        }
    }

    static func requiredString(_ key: String, in arguments: [String: Any],
                               allowEmpty: Bool = false) throws -> String {
        guard let value = arguments[key] as? String,
              allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.invalidArguments("`\(key)` must be a non-empty string")
        }
        return value
    }

    static func requiredEnum(_ key: String, in arguments: [String: Any],
                             allowed: Set<String>) throws -> String {
        let value = try requiredString(key, in: arguments)
        guard allowed.contains(value) else {
            throw AgentToolError.invalidArguments(
                "`\(key)` must be one of \(allowed.sorted().joined(separator: ", "))")
        }
        return value
    }

    private static func requireCoordinate(_ key: String,
                                          in arguments: [String: Any]) throws {
        guard let values = arguments[key] as? [Any], values.count == 2,
              values.allSatisfy({ $0 is NSNumber }) else {
            throw AgentToolError.invalidArguments(
                "`\(key)` must be exactly two numeric coordinates")
        }
    }
}

struct AgentToolProjection {
    private static let projectionLock = NSLock()
    let endpoint: URL
    let token: String

    func project(into assistant: AssistantDefinition) throws {
        try project(into: assistant.directory)
    }

    func project(into directory: URL) throws {
        // Multiple conversations of one assistant intentionally share the
        // same generated .opencode tree. Serialize the tiny atomic refresh so
        // concurrent agents cannot remove or move each other's staging dir.
        Self.projectionLock.lock()
        defer { Self.projectionLock.unlock() }
        let root = directory.appendingPathComponent(".opencode/tools")
        let staging = directory.appendingPathComponent(
            ".opencode/.tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for (name, source) in sources() {
                try Data(source.utf8).write(
                    to: staging.appendingPathComponent("\(name).ts"), options: [.atomic])
            }
            if FileManager.default.fileExists(atPath: root.path) {
                try FileManager.default.removeItem(at: root)
            }
            try FileManager.default.moveItem(at: staging, to: root)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    private func sources() -> [(String, String)] {
        let schemas: [(String, String, String)] = [
            ("voiceflow_computer", "Look at or control the user's Mac through Voice Flow. A screenshot returns a bounded absolute image path; call read on that path to see pixels.",
             "action: tool.schema.enum(['screenshot','cursor_position','left_click','right_click','double_click','mouse_move','drag','type','key','scroll','wait']), coordinate: tool.schema.array(tool.schema.number()).length(2).optional(), start_coordinate: tool.schema.array(tool.schema.number()).length(2).optional(), text: tool.schema.string().optional(), direction: tool.schema.enum(['up','down','left','right']).optional(), amount: tool.schema.number().int().min(1).max(30).optional(), duration: tool.schema.number().min(0).max(30).optional()"),
            ("voiceflow_context", "Read bounded Voice Flow captures or recent dictations. Results are paginated and newest-first unless stated otherwise.",
             "operation: tool.schema.enum(['latest_capture','list_captures','recent_dictations']), limit: tool.schema.number().int().min(1).max(40).optional(), cursor: tool.schema.string().optional()"),
            ("voiceflow_overlay", "Create, update, remove, or list session-scoped Voice Flow overlays.",
             "operation: tool.schema.enum(['show_guide','update_guide','show_panel','annotate','remove','list']), id: tool.schema.string().max(80).optional(), payload: tool.schema.record(tool.schema.string(), tool.schema.any()).optional()"),
            ("voiceflow_user", "Report to the user or collect a response within this Voice Flow Assistant run.",
             "operation: tool.schema.enum(['report','ask','check','wait']), summary: tool.schema.string().max(500).optional(), details: tool.schema.string().max(8000).optional(), question: tool.schema.string().max(2000).optional(), timeout_seconds: tool.schema.number().int().min(5).max(14400).optional()"),
            ("voiceflow_memory", "Read or atomically update the current assistant's bounded core memory or ledger. Update requires the exact revision returned by read; secrets are rejected.",
             "operation: tool.schema.enum(['read','update']), kind: tool.schema.enum(['core','ledger']), content: tool.schema.string().optional(), expected_revision: tool.schema.string().optional()"),
            ("voiceflow_queue", "Read or update the user's small on-screen next-task queue. Only add items the user explicitly asked to queue — never populate it on your own. done/remove need an id from list.",
             "operation: tool.schema.enum(['list','add','done','remove']), texts: tool.schema.array(tool.schema.string().max(200)).max(10).optional(), text: tool.schema.string().max(200).optional(), id: tool.schema.string().optional()"),
        ]
        return schemas.map { name, description, arguments in
            (name, source(name: name, description: description, arguments: arguments))
        }
    }

    private func source(name: String, description: String, arguments: String) -> String {
        """
        import { tool } from "@opencode-ai/plugin"

        export default tool({
          description: \(js(description)),
          args: { \(arguments) },
          async execute(args, context) {
            const response = await fetch(\(js(endpoint.absoluteString)), {
              method: "POST",
              headers: { "authorization": "Bearer \(token)", "content-type": "application/json" },
              body: JSON.stringify({
                tool: \(js(name)), arguments: args,
                session_id: context.sessionID, message_id: context.messageID,
                directory: context.directory
              })
            })
            const text = await response.text()
            if (!response.ok) throw new Error(`Voice Flow tool failed (${response.status}): ${text}`)
            return text
          }
        })
        """
    }

    private func js(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8)!
    }
}
