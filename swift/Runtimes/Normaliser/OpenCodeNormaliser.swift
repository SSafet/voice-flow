import Foundation

// OpenCode's server-sent events (06 §3.7). The external session id is known
// before the stream starts, so this never emits `turnStarted`; it reads only
// this session's parts, turns a growing text snapshot into the piece that is
// new, and lets the caller's reply through `finish` end the turn.

final class OpenCodeNormaliser: RuntimeNormaliserBase {
    let sessionID: String
    private var assistantMessageID: String?
    private var snapshots: [String: String] = [:]

    init(sessionID: String, child: RuntimeChildContext? = nil) {
        self.sessionID = sessionID
        super.init(child: child)
    }

    override func accept(_ line: Data) -> [RuntimeEvent] {
        guard !hasEnded,
              let object = normaliserObject(line),
              let type = object["type"] as? String,
              let properties = object["properties"] as? [String: Any] else { return [] }
        switch type {
        case "message.updated":
            if let info = properties["info"] as? [String: Any],
               (info["sessionID"] as? String) == sessionID,
               (info["role"] as? String) == "assistant" {
                assistantMessageID = info["id"] as? String
            }
            return []
        case "message.part.updated":
            guard let part = properties["part"] as? [String: Any] else { return [] }
            guard frameSession(part: part, properties: properties) == sessionID else { return [] }
            return partUpdated(part)
        case "permission.asked", "permission.updated":
            guard (properties["sessionID"] as? String) == sessionID,
                  let id = properties["id"] as? String else { return [] }
            let title = properties["permission"] as? String ?? "permission"
            let patterns = properties["patterns"] as? [String] ?? []
            return [.permissionAsked(key: id, title: title, detail: patterns.joined(separator: ", "))]
        case "session.error":
            guard (properties["sessionID"] as? String) == sessionID else { return [] }
            return failTurn(code: "runtime_unavailable", message: errorMessage(properties),
                            retryable: false)
        default:
            return []
        }
    }

    // ── Parts ──

    private func partUpdated(_ part: [String: Any]) -> [RuntimeEvent] {
        guard let key = part["id"] as? String else { return [] }
        switch part["type"] as? String {
        case "text":
            guard let delta = snapshotDelta(part, key: key) else { return [] }
            return stream(key: key, on: .text, text: delta, draft: normaliserMessageDraft(key: key))
        case "reasoning":
            guard let delta = snapshotDelta(part, key: key) else { return [] }
            return stream(key: key, on: .reasoning, text: delta,
                          draft: normaliserReasoningDraft(key: key))
        case "tool":
            return toolPart(part, key: key)
        default:
            return []
        }
    }

    /// The piece a snapshot added since the last one. A snapshot that has not
    /// grown produces nothing, one that went backwards is ignored, and an
    /// explicit delta is used when the snapshot cannot say.
    private func snapshotDelta(_ part: [String: Any], key: String) -> String? {
        let text = part["text"] as? String
        let explicit = part["delta"] as? String
        if let explicit, text == nil { return explicit.isEmpty ? nil : explicit }
        guard let text else { return nil }
        guard let previous = snapshots[key] else {
            snapshots[key] = text
            return text.isEmpty ? nil : text
        }
        if text == previous { return nil }
        if text.hasPrefix(previous) {
            snapshots[key] = text
            let suffix = String(text.dropFirst(previous.count))
            return suffix.isEmpty ? nil : suffix
        }
        if text.count < previous.count { return nil }
        snapshots[key] = text
        return explicit.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func toolPart(_ part: [String: Any], key: String) -> [RuntimeEvent] {
        let toolName = part["tool"] as? String ?? "tool"
        let state = part["state"] as? [String: Any] ?? [:]
        let status = state["status"] as? String
        let finished = status == "completed" || status == "error"
        guard open[key] != nil else {
            if finished { return finishTool(key: key, toolName: toolName, state: state,
                                            failed: status == "error") }
            return begin(key: key, draft: toolDraft(key: key, toolName: toolName, state: state))
        }
        if finished {
            return finishTool(key: key, toolName: toolName, state: state, failed: status == "error")
        }
        var draft = openDraft(key) ?? toolDraft(key: key, toolName: toolName, state: state)
        let base = draft.toolCall
        draft.toolCall = TPToolCall(
            errorMessage: base?.errorMessage,
            inputJSON: normaliserJSON(state["input"]) ?? base?.inputJSON,
            kind: base?.kind ?? toolKind(toolName),
            locations: base?.locations,
            name: base?.name ?? toolName,
            output: base?.output,
            title: state["title"] as? String ?? base?.title ?? toolName)
        return update(key: key, draft: draft)
    }

    private func toolDraft(key: String, toolName: String, state: [String: Any]) -> RuntimeItemDraft {
        let title = state["title"] as? String ?? toolName
        return RuntimeItemDraft(key: key, kind: .toolCall, status: .inProgress,
                                toolCall: TPToolCall(errorMessage: nil,
                                                     inputJSON: normaliserJSON(state["input"]),
                                                     kind: toolKind(toolName), locations: nil,
                                                     name: toolName, output: nil, title: title))
    }

    private func finishTool(key: String, toolName: String, state: [String: Any],
                            failed: Bool) -> [RuntimeEvent] {
        var draft = openDraft(key) ?? toolDraft(key: key, toolName: toolName, state: state)
        let base = draft.toolCall
        var output: [TPToolOutput]? = base?.output
        if let text = state["output"] as? String {
            let cut = normaliserCut(text, maxBytes: TOOL_OUTPUT_MAX_BYTES)
            output = [TPToolOutput(newText: nil, oldText: nil, path: nil, text: cut.text, type: .text)]
        }
        draft.toolCall = TPToolCall(
            errorMessage: failed ? (state["error"] as? String ?? base?.errorMessage) : base?.errorMessage,
            inputJSON: normaliserJSON(state["input"]) ?? base?.inputJSON,
            kind: base?.kind ?? toolKind(toolName),
            locations: base?.locations,
            name: base?.name ?? toolName,
            output: output,
            title: state["title"] as? String ?? base?.title ?? toolName)
        draft.status = failed ? .failed : .completed
        return complete(key: key, draft: draft)
    }

    // ── Helpers ──

    private func frameSession(part: [String: Any], properties: [String: Any]) -> String? {
        (part["sessionID"] as? String) ?? (properties["sessionID"] as? String)
    }

    private func toolKind(_ name: String) -> TPToolKind {
        switch name.lowercased() {
        case "bash", "shell", "exec", "command", "run": return .execute
        case "read", "view": return .read
        case "edit", "write", "patch", "apply_patch": return .edit
        case "grep", "glob", "list", "search": return .search
        case "webfetch", "fetch": return .fetch
        case "delete", "remove": return .delete
        case "move", "mv": return .move
        default: return .other
        }
    }

    private func errorMessage(_ properties: [String: Any]) -> String {
        if let error = properties["error"] as? [String: Any] {
            return error["message"] as? String ?? error["data"] as? String
                ?? "OpenCode reported an error"
        }
        if let error = properties["error"] as? String { return error }
        return "OpenCode reported an error"
    }
}
