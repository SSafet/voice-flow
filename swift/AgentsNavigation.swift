import Foundation

// MARK: - Mission Control identity and destinations

enum AgentsDestination: String, CaseIterable {
    case now
    case assistants
    case automations
    case threads

    var label: String {
        switch self {
        case .now: return "Now"
        case .assistants: return "Setup"
        case .automations: return "Automations"
        case .threads: return "Threads"
        }
    }

    /// What the nav bar shows: the two reading surfaces first, then one
    /// setup surface. Assistants and automations are both configuration —
    /// in daily use they hold one assistant and no automations — so they
    /// share the Setup screen instead of each owning a top-level tab.
    static let navigation: [AgentsDestination] = [.now, .threads, .assistants]

    /// The nav item that lights up for this destination.
    var navigationItem: AgentsDestination { self == .automations ? .assistants : self }
}

enum AgentsThreadSource: String, Hashable {
    case assistant
    case mcp
}

struct AgentsThreadID: Hashable {
    let source: AgentsThreadSource
    let value: String
}

/// Every cross-destination action carries a typed identifier. Equal titles or
/// previews can never make Search/Now open an object from the wrong store.
enum AgentsObjectID: Hashable {
    case assistant(slug: String)
    case automation(jobID: String)
    case thread(AgentsThreadID)

    var destination: AgentsDestination {
        switch self {
        case .assistant: return .assistants
        case .automation: return .automations
        case .thread: return .threads
        }
    }

    fileprivate var stableKey: String {
        switch self {
        case .assistant(let slug): return "assistant:\(slug)"
        case .automation(let jobID): return "automation:\(jobID)"
        case .thread(let id): return "thread:\(id.source.rawValue):\(id.value)"
        }
    }
}

// MARK: - Thread projection

enum AgentsThreadGroup: Int, CaseIterable {
    case needsYou
    case unread
    case live
    case recent
    case done

    var label: String {
        switch self {
        case .needsYou: return "Needs you"
        case .unread: return "Unread"
        case .live: return "Live"
        case .recent: return "Recent"
        case .done: return "Done"
        }
    }
}

enum AgentsThreadFilter: Int, CaseIterable {
    case open
    case needs
    case unread
    case live
    case done

    var label: String {
        switch self {
        case .open: return "Open"
        case .needs: return "Needs"
        case .unread: return "Unread"
        case .live: return "Live"
        case .done: return "Done"
        }
    }
}

struct AgentsThreadProjectionInput: Equatable {
    let id: AgentsThreadID
    let title: String
    let owner: String
    let preview: String
    let updatedAt: Date
    let unread: Bool
    let pendingAsk: Bool
    let live: Bool
    let archived: Bool
    /// Evidence of active execution. Live means reachable (a connected
    /// external session); running means work is verifiably happening. Only
    /// running earns a place in Now's "Running now" section.
    var running: Bool = false
}

enum AgentsThreadProjection {
    /// Precedence is part of the product contract: archive is a separate
    /// collection; otherwise an ask outranks unread, which outranks live.
    static func group(for thread: AgentsThreadProjectionInput) -> AgentsThreadGroup {
        if thread.archived { return .done }
        if thread.pendingAsk { return .needsYou }
        if thread.unread { return .unread }
        if thread.live { return .live }
        return .recent
    }

    static func grouped(_ threads: [AgentsThreadProjectionInput])
        -> [AgentsThreadGroup: [AgentsThreadProjectionInput]] {
        var result: [AgentsThreadGroup: [AgentsThreadProjectionInput]] = [:]
        for thread in threads { result[group(for: thread), default: []].append(thread) }
        for group in AgentsThreadGroup.allCases {
            result[group]?.sort {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                if $0.title != $1.title {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return $0.id.value < $1.id.value
            }
        }
        return result
    }

    /// The destination badge counts thread-shaped obligations, not messages:
    /// one open thread contributes at most one even when it both needs an
    /// answer and contains unread output. Neutral live/recent work is not an
    /// interruption and completed history never contributes.
    static func attentionCount(_ threads: [AgentsThreadProjectionInput]) -> Int {
        Set(threads.lazy.filter {
            !$0.archived && ($0.pendingAsk || $0.unread)
        }.map(\.id)).count
    }

    static func filtered(_ threads: [AgentsThreadProjectionInput],
                         by filter: AgentsThreadFilter)
        -> [AgentsThreadProjectionInput] {
        let matching = threads.filter { thread in
            switch filter {
            case .open: return !thread.archived
            case .needs: return !thread.archived && thread.pendingAsk
            case .unread: return !thread.archived && thread.unread
            case .live: return !thread.archived && thread.live
            case .done: return thread.archived
            }
        }
        return matching.sorted(by: destinationOrder)
    }

    /// Open uses mutually-exclusive precedence sections. Dedicated filters
    /// intentionally overlap by state dimension, but are returned as a
    /// single deterministic list.
    static func sections(_ threads: [AgentsThreadProjectionInput],
                         for filter: AgentsThreadFilter)
        -> [(group: AgentsThreadGroup, rows: [AgentsThreadProjectionInput])] {
        if filter == .open {
            let groups = grouped(threads)
            return [AgentsThreadGroup.needsYou, .unread, .live, .recent].compactMap { group in
                guard let rows = groups[group], !rows.isEmpty else { return nil }
                return (group, rows)
            }
        }
        let rows = filtered(threads, by: filter)
        guard !rows.isEmpty else { return [] }
        let group: AgentsThreadGroup
        switch filter {
        case .needs: group = .needsYou
        case .unread: group = .unread
        case .live: group = .live
        case .done: group = .done
        case .open: group = .recent
        }
        return [(group, rows)]
    }

    private static func destinationOrder(_ lhs: AgentsThreadProjectionInput,
                                         _ rhs: AgentsThreadProjectionInput) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.title != rhs.title {
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
        if lhs.id.source != rhs.id.source {
            return lhs.id.source.rawValue < rhs.id.source.rawValue
        }
        return lhs.id.value < rhs.id.value
    }
}

// MARK: - Automation projection

/// UI-facing mirror of the durable job states. Adapters must initialize this
/// from `AgentJobState.rawValue`; an unknown future state fails closed instead
/// of being presented as healthy or ready.
enum AgentsAutomationState: String, CaseIterable {
    case queued
    case running
    case blocked
    case failed
    case completed
    case cancelled
    case disabled
}

enum AgentsAutomationGroup: Int, CaseIterable {
    case needsAttention
    case activeUpcoming
    case ready
    case disabled

    var label: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .activeUpcoming: return "Active & upcoming"
        case .ready: return "Ready"
        case .disabled: return "Disabled"
        }
    }
}

struct AgentsAutomationProjectionInput: Equatable {
    let id: String
    let name: String
    let assistantName: String
    let updatedAt: Date
    let state: AgentsAutomationState
    let isEnabled: Bool

    init(id: String, name: String, assistantName: String,
         updatedAt: Date, state: AgentsAutomationState,
         isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.assistantName = assistantName
        self.updatedAt = updatedAt
        self.state = state
        self.isEnabled = isEnabled
    }
}

enum AgentsAutomationProjection {
    static func group(for automation: AgentsAutomationProjectionInput) -> AgentsAutomationGroup {
        if !automation.isEnabled { return .disabled }
        switch automation.state {
        case .blocked, .failed:
            return .needsAttention
        case .running, .queued:
            return .activeUpcoming
        case .completed:
            return .ready
        case .cancelled, .disabled:
            return .disabled
        }
    }

    static func grouped(_ automations: [AgentsAutomationProjectionInput])
        -> [AgentsAutomationGroup: [AgentsAutomationProjectionInput]] {
        var result: [AgentsAutomationGroup: [AgentsAutomationProjectionInput]] = [:]
        for automation in automations {
            result[group(for: automation), default: []].append(automation)
        }
        for group in AgentsAutomationGroup.allCases {
            result[group]?.sort { lhs, rhs in
                let lhsRank = stateRank(lhs.state)
                let rhsRank = stateRank(rhs.state)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                if lhs.name != rhs.name {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.id < rhs.id
            }
        }
        return result
    }

    private static func stateRank(_ state: AgentsAutomationState) -> Int {
        switch state {
        case .blocked: return 0
        case .failed: return 1
        case .running: return 0
        case .queued: return 1
        case .completed: return 0
        case .disabled: return 0
        case .cancelled: return 1
        }
    }
}

// MARK: - Now

enum AgentsNowKind: Int {
    case pendingAsk
    case blockedAutomation
    case failedAutomation
    case runningAutomation
    case runningThread
    case unreadThread
}

struct AgentsNowItem: Equatable {
    let objectID: AgentsObjectID
    let kind: AgentsNowKind
    let title: String
    let owner: String
    let summary: String
    let updatedAt: Date

    var needsAttention: Bool {
        switch kind {
        case .pendingAsk, .blockedAutomation, .failedAutomation: return true
        case .runningAutomation, .runningThread, .unreadThread: return false
        }
    }
}

struct AgentsNowSnapshot: Equatable {
    let needsYou: [AgentsNowItem]
    let running: [AgentsNowItem]
    /// Open threads with unseen output. Now answers "what is here for me?",
    /// and an unread reply is for the user just as much as an ask is — the
    /// panel must never open on "All clear" while replies wait unread.
    let unread: [AgentsNowItem]

    var attentionCount: Int { needsYou.count }
    var isEmpty: Bool { needsYou.isEmpty && running.isEmpty && unread.isEmpty }
}

enum AgentsNowProjection {
    static func snapshot(threads: [AgentsThreadProjectionInput],
                         automations: [AgentsAutomationProjectionInput]) -> AgentsNowSnapshot {
        var needs: [AgentsNowItem] = []
        var running: [AgentsNowItem] = []
        var unread: [AgentsNowItem] = []

        for thread in threads where !thread.archived {
            if thread.pendingAsk {
                needs.append(AgentsNowItem(
                    objectID: .thread(thread.id), kind: .pendingAsk,
                    title: thread.title, owner: thread.owner,
                    summary: thread.preview, updatedAt: thread.updatedAt))
            } else if thread.running {
                running.append(AgentsNowItem(
                    objectID: .thread(thread.id), kind: .runningThread,
                    title: thread.title, owner: thread.owner,
                    summary: thread.preview, updatedAt: thread.updatedAt))
            } else if thread.unread {
                unread.append(AgentsNowItem(
                    objectID: .thread(thread.id), kind: .unreadThread,
                    title: thread.title, owner: thread.owner,
                    summary: thread.preview, updatedAt: thread.updatedAt))
            }
        }

        for automation in automations where automation.isEnabled {
            let objectID = AgentsObjectID.automation(jobID: automation.id)
            switch automation.state {
            case .blocked:
                needs.append(AgentsNowItem(
                    objectID: objectID, kind: .blockedAutomation,
                    title: automation.name, owner: automation.assistantName,
                    summary: "Budget or permission blocked", updatedAt: automation.updatedAt))
            case .failed:
                needs.append(AgentsNowItem(
                    objectID: objectID, kind: .failedAutomation,
                    title: automation.name, owner: automation.assistantName,
                    summary: "Automation failed", updatedAt: automation.updatedAt))
            case .running:
                running.append(AgentsNowItem(
                    objectID: objectID, kind: .runningAutomation,
                    title: automation.name, owner: automation.assistantName,
                    summary: "Running", updatedAt: automation.updatedAt))
            case .queued, .completed, .cancelled, .disabled:
                break
            }
        }

        needs.sort(by: sortAttention)
        running.sort(by: sortRunning)
        unread.sort(by: sortRunning)
        return AgentsNowSnapshot(needsYou: needs, running: running, unread: unread)
    }

    private static func sortAttention(_ lhs: AgentsNowItem, _ rhs: AgentsNowItem) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.objectID.stableKey < rhs.objectID.stableKey
    }

    private static func sortRunning(_ lhs: AgentsNowItem, _ rhs: AgentsNowItem) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.objectID.stableKey < rhs.objectID.stableKey
    }
}

// MARK: - Typed global search

struct AgentsSearchDocument: Equatable {
    let objectID: AgentsObjectID
    let primaryText: String
    let secondaryText: String
    /// Deliberately supplied, bounded index text only. Callers must never put
    /// raw memory, ledger, attachment contents, credentials, or workspace files
    /// here.
    let indexText: String
    let updatedAt: Date
}

struct AgentsSearchResult: Equatable {
    let objectID: AgentsObjectID
    let destination: AgentsDestination
    let primaryText: String
    let secondaryText: String
    let score: Int
    let updatedAt: Date
}

enum AgentsSearchIndex {
    static func search(_ query: String, in documents: [AgentsSearchDocument],
                       limit: Int = 50) -> [AgentsSearchResult] {
        let tokens = normalized(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty, limit > 0 else { return [] }

        var results: [AgentsSearchResult] = []
        for document in documents {
            let primary = normalized(document.primaryText)
            let secondary = normalized(document.secondaryText)
            let body = normalized(document.indexText)
            var score = 0
            var matchesEveryToken = true
            for token in tokens {
                if primary.hasPrefix(token) { score += 100 }
                else if primary.contains(token) { score += 60 }
                else if secondary.contains(token) { score += 30 }
                else if body.contains(token) { score += 10 }
                else {
                    matchesEveryToken = false
                    break
                }
            }
            guard matchesEveryToken else { continue }
            results.append(AgentsSearchResult(
                objectID: document.objectID,
                destination: document.objectID.destination,
                primaryText: document.primaryText,
                secondaryText: document.secondaryText,
                score: score,
                updatedAt: document.updatedAt))
        }

        return Array(results.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.objectID.stableKey < rhs.objectID.stableKey
        }.prefix(limit))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
