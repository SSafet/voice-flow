import Foundation

// The Codex app-server stream (06 §3.7). The pinned server sends newline-
// delimited JSON-RPC notifications; this reads exactly the methods the
// shipping adapter already knows, and turns an item type it does not know into
// an ordinary `other` tool call rather than losing it.

final class CodexNormaliser: RuntimeNormaliserBase {
    override init(child: RuntimeChildContext? = nil) { super.init(child: child) }

    override func accept(_ line: Data) -> [RuntimeEvent] {
        guard !hasEnded,
              let object = normaliserObject(line),
              let method = object["method"] as? String,
              let params = object["params"] as? [String: Any] else { return [] }
        switch method {
        case "turn/started":
            guard let threadID = params["threadId"] as? String else { return [] }
            return [.turnStarted(externalSessionID: threadID)]
        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return [] }
            return startItem(item)
        case "item/completed":
            guard let item = params["item"] as? [String: Any] else { return [] }
            return completeItem(item)
        case "item/commandExecution/outputDelta", "item/fileChange/outputDelta":
            guard let itemID = params["itemId"] as? String,
                  let delta = params["delta"] as? String else { return [] }
            return outputDelta(key: itemID, text: delta)
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return [] }
            let key = params["itemId"] as? String ?? "assistant_message"
            return stream(key: key, on: .text, text: delta, draft: normaliserMessageDraft(key: key))
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            guard let delta = params["delta"] as? String else { return [] }
            let key = params["itemId"] as? String ?? "reasoning"
            return stream(key: key, on: .reasoning, text: delta,
                          draft: normaliserReasoningDraft(key: key))
        case "turn/plan/updated":
            return planEvent(params)
        case "thread/tokenUsage/updated":
            return usageEvent(params)
        case "turn/completed", "turn/failed", "turn/interrupted":
            return endFromTurn(method: method, params: params)
        default:
            return []
        }
    }

    // ── Items ──

    private func startItem(_ item: [String: Any]) -> [RuntimeEvent] {
        let type = item["type"] as? String ?? ""
        let key = item["id"] as? String ?? fallbackKey(type)
        switch type {
        case "commandExecution":
            let title = item["command"] as? String ?? ""
            return begin(key: key, draft: toolDraft(key: key, name: "commandExecution",
                                                    kind: .execute, title: title, item: item))
        case "fileChange":
            return begin(key: key, draft: toolDraft(key: key, name: "fileChange",
                                                    kind: .edit, title: changeTitle(item), item: item))
        case "mcpToolCall":
            let name = item["tool"] as? String ?? item["name"] as? String ?? "mcpToolCall"
            return begin(key: key, draft: toolDraft(key: key, name: name,
                                                    kind: .other, title: name, item: item))
        case "webSearch":
            let query = item["query"] as? String ?? ""
            return begin(key: key, draft: toolDraft(key: key, name: "webSearch",
                                                    kind: .search, title: query, item: item))
        case "agentMessage":
            return begin(key: key, draft: normaliserMessageDraft(key: key))
        case "reasoning":
            return begin(key: key, draft: normaliserReasoningDraft(key: key))
        case "contextCompaction":
            return begin(key: key, draft: normaliserNoticeDraft(key: key, code: .compaction,
                                                               message: "compacted"))
        default:
            let name = type.isEmpty ? "unknown" : type
            return begin(key: key, draft: normaliserOtherToolDraft(key: key, name: name, title: type))
        }
    }

    private func completeItem(_ item: [String: Any]) -> [RuntimeEvent] {
        let type = item["type"] as? String ?? ""
        let itemID = item["id"] as? String
        switch type {
        case "commandExecution":
            let key = itemID ?? openKey(kind: .toolCall) ?? "command"
            let command = item["command"] as? String ?? openDraft(key)?.toolCall?.title ?? ""
            let statusText = item["status"] as? String
            let exit = normaliserInt(item["exitCode"])
            let failed = (statusText != nil && statusText != "completed") || (exit != nil && exit != 0)
            var draft = openDraft(key) ?? RuntimeItemDraft(key: key, kind: .toolCall, status: .inProgress)
            let base = draft.toolCall
            draft.toolCall = TPToolCall(
                errorMessage: failed ? (item["error"] as? String ?? "the command failed") : base?.errorMessage,
                inputJSON: base?.inputJSON,
                kind: .execute,
                locations: base?.locations,
                name: "commandExecution",
                output: terminalOutput(item["aggregatedOutput"] as? String),
                title: command)
            draft.status = failed ? .failed : .completed
            return complete(key: key, draft: draft)
        case "agentMessage":
            let key = openKey(kind: .assistantMessage) ?? itemID ?? "assistant_message"
            let draft = openDraft(key) ?? normaliserMessageDraft(key: key)
            let text = item["text"] as? String ?? accumulatedText(key) ?? ""
            return completeMessage(key: key, draft: draft, text: text)
        case "reasoning":
            let key = openKey(kind: .reasoning) ?? itemID ?? "reasoning"
            let draft = openDraft(key) ?? normaliserReasoningDraft(key: key)
            let text = item["text"] as? String ?? accumulatedText(key) ?? ""
            return completeMessage(key: key, draft: draft, text: text)
        case "contextCompaction":
            let key = itemID ?? openKey(kind: .notice) ?? "compaction"
            return complete(key: key, draft: normaliserNoticeDraft(key: key, code: .compaction,
                                                                   message: "compacted"))
        default:
            let key = itemID ?? openKey(kind: .toolCall) ?? "item"
            let name = type.isEmpty ? "unknown" : type
            var draft = openDraft(key) ?? normaliserOtherToolDraft(key: key, name: name, title: type)
            let base = draft.toolCall
            let statusText = item["status"] as? String
            let failed = statusText == "failed"
            draft.toolCall = TPToolCall(
                errorMessage: failed ? (item["error"] as? String ?? base?.errorMessage) : base?.errorMessage,
                inputJSON: base?.inputJSON,
                kind: base?.kind ?? .other,
                locations: base?.locations,
                name: base?.name ?? name,
                output: base?.output,
                title: base?.title ?? type)
            draft.status = failed ? .failed : .completed
            return complete(key: key, draft: draft)
        }
    }

    private func outputDelta(key: String, text: String) -> [RuntimeEvent] {
        let draft = normaliserOtherToolDraft(key: key, name: "output", title: "")
        return stream(key: key, on: .output, text: text, draft: draft)
    }

    // ── Plan and usage ──

    private func planEvent(_ params: [String: Any]) -> [RuntimeEvent] {
        guard let raw = params["plan"] as? [[String: Any]] else { return [] }
        let entries = raw.map { entry -> TPPlanEntry in
            let content = entry["step"] as? String ?? entry["content"] as? String ?? ""
            return TPPlanEntry(content: content,
                               priority: normaliserPlanPriority(entry["priority"] as? String),
                               status: normaliserPlanEntryStatus(entry["status"] as? String))
        }
        let draft = RuntimeItemDraft(key: "plan", kind: .plan, status: .inProgress,
                                     plan: TPPlan(entries: entries))
        if open["plan"] != nil { return update(key: "plan", draft: draft) }
        return begin(key: "plan", draft: draft)
    }

    private func usageEvent(_ params: [String: Any]) -> [RuntimeEvent] {
        guard let tokenUsage = params["tokenUsage"] as? [String: Any] else { return [] }
        let last = tokenUsage["last"] as? [String: Any] ?? [:]
        let window = normaliserInt(tokenUsage["modelContextWindow"])
        let input = normaliserInt(last["inputTokens"])
        let output = normaliserInt(last["outputTokens"])
        guard input != nil || output != nil || window != nil else { return [] }
        return [.usage(TPTurnUsage(contextTokens: nil, contextWindow: window, costMicros: nil,
                                   costSettled: nil, inputTokens: input, outputTokens: output))]
    }

    // ── Turn end ──

    private func endFromTurn(method: String, params: [String: Any]) -> [RuntimeEvent] {
        let turn = params["turn"] as? [String: Any] ?? [:]
        let status = turn["status"] as? String
            ?? (method == "turn/failed" ? "failed"
                : method == "turn/interrupted" ? "interrupted" : "completed")
        switch status {
        case "failed":
            let message = (turn["error"] as? [String: Any])?["message"] as? String
                ?? (params["error"] as? [String: Any])?["message"] as? String
                ?? params["message"] as? String
                ?? "the runtime reported a failed turn"
            return failTurn(code: "runtime_unavailable", message: message, retryable: true)
        case "interrupted":
            return stopTurn()
        default:
            return successTurn()
        }
    }

    // ── Helpers ──

    private func fallbackKey(_ type: String) -> String {
        switch type {
        case "agentMessage": return "assistant_message"
        case "reasoning": return "reasoning"
        case "contextCompaction": return "compaction"
        default: return "item"
        }
    }

    private func toolDraft(key: String, name: String, kind: TPToolKind, title: String,
                           item: [String: Any]) -> RuntimeItemDraft {
        RuntimeItemDraft(key: key, kind: .toolCall, status: .inProgress,
                         toolCall: TPToolCall(errorMessage: nil, inputJSON: normaliserJSON(item["input"]),
                                              kind: kind, locations: nil, name: name,
                                              output: nil, title: title))
    }

    private func changeTitle(_ item: [String: Any]) -> String {
        if let changes = item["changes"] as? [[String: Any]],
           let path = changes.first?["path"] as? String { return path }
        return item["path"] as? String ?? ""
    }

    private func terminalOutput(_ text: String?) -> [TPToolOutput]? {
        guard let text else { return nil }
        let cut = normaliserCut(text, maxBytes: TOOL_OUTPUT_MAX_BYTES)
        return [TPToolOutput(newText: nil, oldText: nil, path: nil, text: cut.text, type: .terminal)]
    }
}
