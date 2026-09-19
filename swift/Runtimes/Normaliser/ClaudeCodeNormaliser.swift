import Foundation

// The `claude -p` stream-json stream (06 §3.7). It reads the frames the
// shipping adapter already knows, keeps a tool's file path as a location, turns
// the task list into one plan item rather than a tool call, and hangs a vendor
// helper's work under the call that started it.

final class ClaudeCodeNormaliser: RuntimeNormaliserBase {
    private var parentTools: [String: String] = [:]
    private var parentAgents: [String: String] = [:]

    override init(child: RuntimeChildContext? = nil) { super.init(child: child) }

    override func accept(_ line: Data) -> [RuntimeEvent] {
        guard !hasEnded,
              let object = normaliserObject(line),
              let type = object["type"] as? String else { return [] }
        switch type {
        case "system":
            guard object["subtype"] as? String == "init",
                  let session = object["session_id"] as? String else { return [] }
            return [.turnStarted(externalSessionID: session)]
        case "stream_event":
            guard let event = object["event"] as? [String: Any] else { return [] }
            return streamEvent(event)
        case "user":
            return userMessage(object)
        case "assistant":
            return assistantMessage(object)
        case "result":
            return result(object)
        default:
            return []
        }
    }

    // ── Streaming ──

    private func streamEvent(_ event: [String: Any]) -> [RuntimeEvent] {
        switch event["type"] as? String {
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any] else { return [] }
            if (delta["type"] as? String) == "text_delta", let text = delta["text"] as? String {
                return stream(key: "assistant_message", on: .text, text: text,
                              draft: normaliserMessageDraft(key: "assistant_message"))
            }
            if (delta["type"] as? String) == "thinking_delta", let text = delta["thinking"] as? String {
                return stream(key: "reasoning", on: .reasoning, text: text,
                              draft: normaliserReasoningDraft(key: "reasoning"))
            }
            return []
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any] else { return [] }
            return contentBlockStart(block)
        default:
            return []
        }
    }

    private func contentBlockStart(_ block: [String: Any]) -> [RuntimeEvent] {
        guard (block["type"] as? String) == "tool_use", let id = block["id"] as? String else { return [] }
        let name = block["name"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        parentTools[id] = name
        parentAgents[id] = input["subagent_type"] as? String
        if name == "TodoWrite" { return plan(input) }
        let draft = RuntimeItemDraft(key: id, kind: .toolCall, status: .inProgress,
                                     toolCall: TPToolCall(errorMessage: nil,
                                                          inputJSON: normaliserJSON(input),
                                                          kind: toolKind(name),
                                                          locations: locations(input),
                                                          name: name, output: nil,
                                                          title: title(name, input)))
        return begin(key: id, draft: draft)
    }

    // ── Messages ──

    private func userMessage(_ object: [String: Any]) -> [RuntimeEvent] {
        let message = object["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? [[String: Any]] ?? []
        var events: [RuntimeEvent] = []
        for block in content where (block["type"] as? String) == "tool_result" {
            guard let callID = block["tool_use_id"] as? String else { continue }
            let isError = (block["is_error"] as? Bool) ?? false
            let outputText = resultText(block["content"]) ?? ""
            var draft = openDraft(callID) ?? normaliserOtherToolDraft(key: callID, name: "tool", title: "")
            let base = draft.toolCall
            let cut = normaliserCut(outputText, maxBytes: TOOL_OUTPUT_MAX_BYTES)
            draft.toolCall = TPToolCall(
                errorMessage: isError ? outputText : base?.errorMessage,
                inputJSON: base?.inputJSON,
                kind: base?.kind ?? .other,
                locations: base?.locations,
                name: base?.name ?? "tool",
                output: [TPToolOutput(newText: nil, oldText: nil, path: nil,
                                      text: cut.text, type: .text)],
                title: base?.title ?? "")
            draft.status = isError ? .failed : .completed
            events += complete(key: callID, draft: draft)
        }
        return events
    }

    private func assistantMessage(_ object: [String: Any]) -> [RuntimeEvent] {
        guard let parentID = object["parent_tool_use_id"] as? String else { return [] }
        let message = object["message"] as? [String: Any] ?? [:]
        let content = message["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined()
        let key = "assistant_message:\(parentID)"
        var draft = RuntimeItemDraft(key: key, kind: .assistantMessage, status: .inProgress)
        draft.agentName = parentAgents[parentID] ?? parentTools[parentID]
        draft.parentKey = parentID
        return completeMessage(key: key, draft: draft, text: text)
    }

    private func result(_ object: [String: Any]) -> [RuntimeEvent] {
        if (object["is_error"] as? Bool) ?? false {
            let message = (object["result"] as? String)
                ?? (object["subtype"] as? String)
                ?? "Claude Code reported an error"
            return failTurn(code: "runtime_unavailable", message: message, retryable: false)
        }
        var events: [RuntimeEvent] = []
        let key = openKey(kind: .assistantMessage) ?? "assistant_message"
        let draft = openDraft(key) ?? normaliserMessageDraft(key: key)
        let text = object["result"] as? String ?? accumulatedText(key) ?? ""
        events += completeMessage(key: key, draft: draft, text: text)
        if let usage = usage(object) { events.append(.usage(usage)) }
        events += successTurn()
        return events
    }

    // ── Plan and usage ──

    private func plan(_ input: [String: Any]) -> [RuntimeEvent] {
        let raw = input["todos"] as? [[String: Any]] ?? []
        let entries = raw.map { todo -> TPPlanEntry in
            TPPlanEntry(content: todo["content"] as? String ?? "",
                        priority: normaliserPlanPriority(todo["priority"] as? String),
                        status: normaliserPlanEntryStatus(todo["status"] as? String))
        }
        let draft = RuntimeItemDraft(key: "plan", kind: .plan, status: .inProgress,
                                     plan: TPPlan(entries: entries))
        if open["plan"] != nil { return update(key: "plan", draft: draft) }
        return begin(key: "plan", draft: draft)
    }

    private func usage(_ object: [String: Any]) -> TPTurnUsage? {
        let usage = object["usage"] as? [String: Any] ?? [:]
        let input = normaliserInt(usage["input_tokens"])
        let output = normaliserInt(usage["output_tokens"])
        var costMicros: Int?
        if let number = object["total_cost_usd"] as? NSNumber {
            costMicros = Int((number.doubleValue * 1_000_000).rounded())
        }
        guard input != nil || output != nil || costMicros != nil else { return nil }
        return TPTurnUsage(contextTokens: nil, contextWindow: nil, costMicros: costMicros,
                           costSettled: true, inputTokens: input, outputTokens: output)
    }

    // ── Helpers ──

    private func toolKind(_ name: String) -> TPToolKind {
        switch name {
        case "Bash", "BashOutput", "KillShell", "Shell": return .execute
        case "Read": return .read
        case "Edit", "Write", "MultiEdit", "NotebookEdit": return .edit
        case "Glob", "Grep", "WebSearch", "Search": return .search
        case "WebFetch", "Fetch": return .fetch
        default: return .other
        }
    }

    private func locations(_ input: [String: Any]) -> [TPToolLocation]? {
        if let path = input["file_path"] as? String { return [TPToolLocation(line: nil, path: path)] }
        if let path = input["path"] as? String { return [TPToolLocation(line: nil, path: path)] }
        return nil
    }

    private func title(_ name: String, _ input: [String: Any]) -> String {
        switch name {
        case "Bash": return input["command"] as? String ?? name
        case "Read", "Edit", "Write", "MultiEdit", "NotebookEdit":
            return input["file_path"] as? String ?? name
        case "WebSearch": return input["query"] as? String ?? name
        case "Grep": return input["pattern"] as? String ?? name
        default: return name
        }
    }

    private func resultText(_ content: Any?) -> String? {
        if let string = content as? String { return string }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined()
        }
        return nil
    }
}
