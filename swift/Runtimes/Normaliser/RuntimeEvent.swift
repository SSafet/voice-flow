import Foundation
import CoreFoundation

// The vocabulary every runtime stream is translated into (06 §3.7, R4). A
// runtime's own words never leave this package: the adapters hand raw lines to
// one normaliser per runtime, and the normaliser emits these contract-shaped
// drafts. It owns no ids, no sequence numbers and no timestamps — the turn
// engine maps a draft key to one item and assigns offsets — and it never
// invents text a runtime did not send.

enum RuntimeItemPhase: String, Equatable { case started, updated, completed }

struct RuntimeChildContext: Equatable { let agentName: String; let parentKey: String }

struct RuntimeItemDraft: Equatable {
    var key: String                    // the runtime's own name for this thing; the engine maps it to an item id
    var kind: TPItemKind
    var status: TPItemStatus
    var text: String? = nil
    var fullText: String? = nil        // set only when truncated; the engine attaches it
    var truncated: Bool = false
    var toolCall: TPToolCall? = nil
    var plan: TPPlan? = nil
    var notice: TPNotice? = nil
    var agentName: String? = nil
    var parentKey: String? = nil
}

enum RuntimeStreamEnd: Equatable {
    case completed(text: String?, usage: TPTurnUsage?)
    case stopped
    case failed(code: String, message: String, retryable: Bool)
}

enum RuntimeEvent: Equatable {
    case turnStarted(externalSessionID: String)
    case item(phase: RuntimeItemPhase, draft: RuntimeItemDraft)
    case delta(key: String, stream: TPDeltaStream, text: String)
    case permissionAsked(key: String, title: String, detail: String)
    case usage(TPTurnUsage)
    case turnEnded(status: TPTurnStatus, stopReason: TPStopReason?, error: TPTurnError?)
}

protocol RuntimeNormaliser: AnyObject {
    func accept(_ line: Data) -> [RuntimeEvent]
    func finish(_ end: RuntimeStreamEnd) -> [RuntimeEvent]
}

/// The contract's byte limits (01 §3.2, records.ts): a draft's text is cut at
/// 200 KiB and a tool's output at 32 KiB, then cleaned, because a lone
/// surrogate would block the mirror.
let ITEM_TEXT_MAX_BYTES = 200 * 1024
let TOOL_OUTPUT_MAX_BYTES = 32 * 1024

/// One newline-delimited JSON object, or nil for a line that is not one.
/// `accept` never throws and never guesses, so an unreadable line is silence.
/// A runtime that puts a raw control character inside a string (Claude Code's
/// result line can carry a NUL) is repaired to its JSON escape before parsing,
/// so the character reaches the cut-and-clean step instead of vanishing.
func normaliserObject(_ line: Data) -> [String: Any]? {
    if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
        return object
    }
    let repaired = normaliserEscapingControlBytes(line)
    guard repaired != line else { return nil }
    guard let object = (try? JSONSerialization.jsonObject(with: repaired)) as? [String: Any] else {
        return nil
    }
    return object
}

func normaliserEscapingControlBytes(_ data: Data) -> Data {
    var out = Data()
    out.reserveCapacity(data.count)
    var inString = false
    var escaped = false
    for byte in data {
        if inString {
            if escaped {
                out.append(byte)
                escaped = false
            } else if byte == 0x5C {
                out.append(byte)
                escaped = true
            } else if byte == 0x22 {
                out.append(byte)
                inString = false
            } else if byte < 0x20 {
                out.append(contentsOf: String(format: "\\u%04x", Int(byte)).utf8)
            } else {
                out.append(byte)
            }
        } else {
            if byte == 0x22 { inString = true }
            out.append(byte)
        }
    }
    return out
}

/// A non-negative whole number, never a boolean.
func normaliserInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value >= 0, value < Double(Int.max), value.rounded(.down) == value else { return nil }
    return number.intValue
}

/// The runtime's input, encoded as the JSON string the contract stores.
func normaliserJSON(_ value: Any?) -> String? {
    guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
    return String(data: data, encoding: .utf8)
}

/// At most `maxBytes` encoded bytes, by UTF-16 code units found with a binary
/// search, then cleaned. A cut text reports itself so the engine can attach the
/// whole one.
func normaliserCut(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
    if text.utf8.count <= maxBytes { return (ContractText.cleanText(text), false) }
    let units = text.utf16.count
    var low = 0
    var high = units
    while low < high {
        let mid = (low + high + 1) / 2
        if ContractText.cutText(text, maxUnits: mid).utf8.count <= maxBytes {
            low = mid
        } else {
            high = mid - 1
        }
    }
    return (ContractText.cleanText(ContractText.cutText(text, maxUnits: low)), true)
}

/// The shared half of the three normalisers: it opens an item once, closes it
/// once, drops what arrives for a closed item, ends the turn exactly once, and
/// stamps a child run's delegate name and parent task on every draft.
class RuntimeNormaliserBase: RuntimeNormaliser {
    struct OpenItem {
        var draft: RuntimeItemDraft
        var text: String
    }

    let child: RuntimeChildContext?
    private(set) var hasEnded = false
    private(set) var open: [String: OpenItem] = [:]
    private var closed: Set<String> = []
    private var openOrder: [String] = []

    init(child: RuntimeChildContext?) {
        self.child = child
    }

    func accept(_ line: Data) -> [RuntimeEvent] { [] }

    // ── Draft helpers ──

    func stamp(_ draft: RuntimeItemDraft) -> RuntimeItemDraft {
        var stamped = draft
        if let child {
            stamped.agentName = child.agentName
            if stamped.parentKey == nil { stamped.parentKey = child.parentKey }
        }
        return stamped
    }

    func openDraft(_ key: String) -> RuntimeItemDraft? { open[key]?.draft }

    func accumulatedText(_ key: String) -> String? { open[key]?.text }

    func openKey(kind: TPItemKind) -> String? {
        openOrder.first { open[$0]?.draft.kind == kind }
    }

    // ── Item lifecycle ──

    func begin(key: String, draft: RuntimeItemDraft) -> [RuntimeEvent] {
        guard !hasEnded, open[key] == nil, !closed.contains(key) else { return [] }
        open[key] = OpenItem(draft: draft, text: "")
        openOrder.append(key)
        return [.item(phase: .started, draft: stamp(draft))]
    }

    func update(key: String, draft: RuntimeItemDraft) -> [RuntimeEvent] {
        guard !hasEnded, open[key] != nil, !closed.contains(key) else { return [] }
        open[key]?.draft = draft
        return [.item(phase: .updated, draft: stamp(draft))]
    }

    func complete(key: String, draft: RuntimeItemDraft) -> [RuntimeEvent] {
        guard !hasEnded, !closed.contains(key) else { return [] }
        var events: [RuntimeEvent] = []
        if open[key] == nil { events.append(.item(phase: .started, draft: stamp(draft))) }
        open.removeValue(forKey: key)
        closed.insert(key)
        events.append(.item(phase: .completed, draft: stamp(draft)))
        return events
    }

    func completeMessage(key: String, draft: RuntimeItemDraft, text: String) -> [RuntimeEvent] {
        var message = draft
        let cut = normaliserCut(text, maxBytes: ITEM_TEXT_MAX_BYTES)
        message.text = cut.text
        message.truncated = cut.truncated
        message.fullText = cut.truncated ? ContractText.cleanText(text) : nil
        message.status = .completed
        return complete(key: key, draft: message)
    }

    func stream(key: String, on deltaStream: TPDeltaStream, text: String, draft: RuntimeItemDraft) -> [RuntimeEvent] {
        guard !hasEnded else { return [] }
        var events: [RuntimeEvent] = []
        if open[key] == nil && !closed.contains(key) { events += begin(key: key, draft: draft) }
        guard open[key] != nil else { return events }
        open[key]?.text += text
        events.append(.delta(key: key, stream: deltaStream, text: ContractText.cleanText(text)))
        return events
    }

    // ── Turn end ──

    func closeOpen(asStatus status: TPItemStatus) -> [RuntimeEvent] {
        var events: [RuntimeEvent] = []
        for key in openOrder {
            guard let item = open[key], !closed.contains(key) else { continue }
            var draft = item.draft
            draft.status = status
            if draft.kind == .assistantMessage || draft.kind == .reasoning, !item.text.isEmpty {
                let cut = normaliserCut(item.text, maxBytes: ITEM_TEXT_MAX_BYTES)
                draft.text = cut.text
                draft.truncated = cut.truncated
                draft.fullText = cut.truncated ? ContractText.cleanText(item.text) : nil
            }
            open.removeValue(forKey: key)
            closed.insert(key)
            events.append(.item(phase: .completed, draft: stamp(draft)))
        }
        return events
    }

    private func markEnded(_ status: TPTurnStatus, _ stopReason: TPStopReason?, _ error: TPTurnError?) -> RuntimeEvent {
        hasEnded = true
        return .turnEnded(status: status, stopReason: stopReason, error: error)
    }

    func successTurn() -> [RuntimeEvent] {
        guard !hasEnded else { return [] }
        var events = closeOpen(asStatus: .completed)
        events.append(markEnded(.completed, .endTurn, nil))
        return events
    }

    func stopTurn() -> [RuntimeEvent] {
        guard !hasEnded else { return [] }
        var events = closeOpen(asStatus: .failed)
        events.append(markEnded(.interrupted, .cancelled, nil))
        return events
    }

    func failTurn(code: String, message: String, retryable: Bool) -> [RuntimeEvent] {
        guard !hasEnded else { return [] }
        var events = closeOpen(asStatus: .failed)
        events.append(markEnded(.failed, nil, TPTurnError(code: code, message: message, retryable: retryable)))
        return events
    }

    func finish(_ end: RuntimeStreamEnd) -> [RuntimeEvent] {
        guard !hasEnded else { return [] }
        switch end {
        case let .completed(text, usage):
            var events: [RuntimeEvent] = []
            for key in openOrder where open[key]?.draft.kind == .assistantMessage {
                guard let item = open[key] else { continue }
                events += completeMessage(key: key, draft: item.draft, text: text ?? item.text)
            }
            if let usage { events.append(.usage(usage)) }
            events += closeOpen(asStatus: .completed)
            events.append(markEnded(.completed, .endTurn, nil))
            return events
        case .stopped:
            return stopTurn()
        case let .failed(code, message, retryable):
            return failTurn(code: code, message: message, retryable: retryable)
        }
    }
}

// ── Shared draft constructors ──

func normaliserMessageDraft(key: String) -> RuntimeItemDraft {
    RuntimeItemDraft(key: key, kind: .assistantMessage, status: .inProgress)
}

func normaliserReasoningDraft(key: String) -> RuntimeItemDraft {
    RuntimeItemDraft(key: key, kind: .reasoning, status: .inProgress)
}

func normaliserNoticeDraft(key: String, code: TPNoticeCode, message: String) -> RuntimeItemDraft {
    RuntimeItemDraft(key: key, kind: .notice, status: .completed,
                     notice: TPNotice(code: code, git: nil, message: message))
}

func normaliserOtherToolDraft(key: String, name: String, title: String,
                              inputJSON: String? = nil, kind: TPToolKind = .other) -> RuntimeItemDraft {
    RuntimeItemDraft(key: key, kind: .toolCall, status: .inProgress,
                     toolCall: TPToolCall(errorMessage: nil, inputJSON: inputJSON, kind: kind,
                                          locations: nil, name: name, output: nil, title: title))
}

func normaliserPlanEntryStatus(_ value: String?) -> TPPlanEntryStatus {
    switch value {
    case "completed": return .completed
    case "in_progress": return .inProgress
    default: return .pending
    }
}

func normaliserPlanPriority(_ value: String?) -> TPPlanPriority {
    switch value {
    case "high": return .high
    case "low": return .low
    default: return .medium
    }
}
