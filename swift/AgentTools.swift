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

/// V2 native plugin with JSON Schema inputs. The plugin has no imports: the
/// Promise plugin API accepts this object directly, so a cold start never
/// installs npm dependencies. Callers write it only into process-private config.
struct AgentToolProjection {
    let endpoint: URL
    let token: String

    @discardableResult
    func project(into directory: URL) throws -> URL {
        let root = directory.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("voiceflow.js")
        try Data(source().utf8).write(to: target, options: .atomic)
        return target
    }

    func source() -> String {
        let definitions: [[String: Any]] = [
            definition("voiceflow_computer", "Look at or control the user's Mac through Voice Flow. A screenshot returns a bounded absolute image path; call read on that path to see pixels.",
                ["action": choice(["screenshot", "cursor_position", "left_click", "right_click", "double_click", "mouse_move", "drag", "type", "key", "scroll", "wait"]),
                 "coordinate": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                 "start_coordinate": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
                 "text": string(), "direction": choice(["up", "down", "left", "right"]),
                 "amount": integer(1, 30), "duration": ["type": "number", "minimum": 0, "maximum": 30]], required: ["action"]),
            definition("voiceflow_context", "Read bounded Voice Flow captures or recent dictations. Results are paginated and newest-first unless stated otherwise.",
                ["operation": choice(["latest_capture", "list_captures", "recent_dictations"]),
                 "limit": integer(1, 40), "cursor": string()], required: ["operation"]),
            definition("voiceflow_overlay", "Create, update, remove, or list session-scoped Voice Flow overlays.",
                ["operation": choice(["show_guide", "update_guide", "show_panel", "annotate", "remove", "list"]),
                 "id": string(80), "payload": ["type": "object", "additionalProperties": true]], required: ["operation"]),
            definition("voiceflow_user", "Report to the user or collect a response within this Voice Flow Assistant run.",
                ["operation": choice(["report", "ask", "check", "wait"]), "summary": string(500),
                 "details": string(8000), "question": string(2000), "timeout_seconds": integer(5, 14400)], required: ["operation"]),
            definition("voiceflow_memory", "Read or atomically update the current assistant's bounded core memory or ledger. Update requires the exact revision returned by read; secrets are rejected.",
                ["operation": choice(["read", "update"]), "kind": choice(["core", "ledger"]),
                 "content": string(), "expected_revision": string()], required: ["operation", "kind"]),
            definition("voiceflow_queue", "Read or update the user's small on-screen next-task queue. Only add items the user explicitly asked to queue — never populate it on your own. done/remove need an id from list.",
                ["operation": choice(["list", "add", "done", "remove"]),
                 "texts": ["type": "array", "items": string(200), "maxItems": 10],
                 "text": string(200), "id": string()], required: ["operation"]),
        ]
        return """
        // OpenCode 2.0.12 Promise plugin contract; no runtime SDK dependency.
        export default {
          id: "voiceflow.native-tools",
          async setup(ctx) {
            const sessions = new Map()
            await ctx.skill.transform(editor => {
              for (const skill of editor.list()) editor.remove(skill.id)
              for (const state of sessions.values()) for (const skill of state.skills) editor.add(skill)
            })
            await ctx.rpc.register({
              id: "voiceflow",
              methods: {
                skills: {
                  input: { type: "object", properties: {
                    sessionID: { type: "string" }, generation: { type: "string" }, remove: { type: "boolean" },
                    skills: { type: "array", items: { type: "object", properties: {
                      id: { type: "string" }, name: { type: "string" },
                      description: { type: "string" }, path: { type: "string" }, content: { type: "string" }
                    }, required: ["id", "name", "description", "path", "content"], additionalProperties: false } }
                  }, required: ["sessionID", "generation", "skills"], additionalProperties: false },
                  output: { type: "boolean" }
                }
              },
              events: {}
            }, {
              async skills(input) {
                if (input.remove) {
                  if (sessions.get(input.sessionID)?.generation !== input.generation) return true
                  sessions.delete(input.sessionID)
                } else {
                  sessions.set(input.sessionID, { generation: input.generation, skills: input.skills })
                }
                await ctx.skill.reload()
                return true
              }
            })
            await ctx.tool.transform(editor => {
              for (const definition of \(json(definitions))) {
                editor.add({
                  ...definition,
                  options: { codemode: false },
                  async execute(args, context) {
                    const response = await fetch(\(json(endpoint.absoluteString)), {
                      method: "POST",
                      signal: context.signal,
                      headers: { "authorization": \(json("Bearer " + token)), "content-type": "application/json" },
                      body: JSON.stringify({
                        tool: definition.name, arguments: args,
                        session_id: context.sessionID, message_id: context.messageID,
                        directory: ctx.location.directory
                      })
                    })
                    const text = await response.text()
                    if (!response.ok) throw new Error(`Voice Flow tool failed (${response.status}): ${text}`)
                    return { content: text }
                  }
                })
              }
            })
          }
        }
        """
    }

    private func definition(_ name: String, _ description: String,
                            _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description,
         "input": ["type": "object", "properties": properties,
                   "required": required, "additionalProperties": false]]
    }
    private func choice(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    private func string(_ maxLength: Int? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "string"]
        if let maxLength { schema["maxLength"] = maxLength }
        return schema
    }
    private func integer(_ minimum: Int, _ maximum: Int) -> [String: Any] {
        ["type": "integer", "minimum": minimum, "maximum": maximum]
    }
    private func json(_ value: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
