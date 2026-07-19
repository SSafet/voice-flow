import Foundation

/// What the user is collecting. Destination is deliberately not encoded here:
/// the same capability can paste, feed the assistant, message one MCP session,
/// or remain only in Dictations.
enum CaptureCapability: String, Codable, Equatable {
    case dictate
    case snapshot
    case continuous
}

/// Input to route resolution. It is not stored beside the resolved route, so
/// policy and route can never drift apart later in the run.
enum CaptureDeliveryPolicy: Equatable {
    case contextual
    case historyOnly
}

/// A conversation counts only while its concrete surface is visible.
enum ConversationFocus: Equatable {
    case none
    case assistant
    case session(String)
}

/// Stable identity for the application that owned focus when capture began.
/// Re-resolving by PID avoids one mutable `Paster` target shared by pending runs.
struct PasteTarget: Equatable {
    let processIdentifier: pid_t
    let name: String
}

enum CaptureRoute {
    case paste(PasteTarget)
    case assistant
    case session(id: String, interaction: PendingInteraction?)
    case historyOnly
}

enum CaptureRunPhase: Equatable {
    case recording
    case awaitingTranscription
    case ready
    case delivered
    case failed
}

enum SnapshotState {
    case notNeeded
    case pending
    case captured(path: String, data: Data)
    case unavailable

    var isTerminal: Bool {
        switch self {
        case .pending: return false
        case .notNeeded, .captured, .unavailable: return true
        }
    }
}

struct CaptureRun {
    let id: UUID
    let capability: CaptureCapability
    let route: CaptureRoute
    let startedAt: Date
    /// Display selected when the hotkey began; never recomputed by an async
    /// screenshot or transcription callback.
    let display: DisplayContext?
    var phase: CaptureRunPhase = .recording
    var transcript: String?
    var snapshot: SnapshotState
    var continuousSummary: CaptureSummary?
    var continuousScreenshots: [Data] = []

    init(id: UUID, capability: CaptureCapability, route: CaptureRoute,
         startedAt: Date, display: DisplayContext? = nil, snapshot: SnapshotState) {
        self.id = id
        self.capability = capability
        self.route = route
        self.startedAt = startedAt
        self.display = display
        self.snapshot = snapshot
    }

    var isReadyToDeliver: Bool {
        guard transcript != nil else { return false }
        switch capability {
        case .dictate:
            return true
        case .snapshot:
            return snapshot.isTerminal
        case .continuous:
            return continuousSummary != nil
        }
    }
}

enum CaptureRouter {
    static func resolve(
        policy: CaptureDeliveryPolicy,
        focus: ConversationFocus,
        pasteTarget: PasteTarget?,
        pendingInteraction: PendingInteraction?
    ) -> CaptureRoute {
        if policy == .historyOnly { return .historyOnly }
        switch focus {
        case .assistant:
            return .assistant
        case .session(let id):
            let interaction = pendingInteraction?.sessionId == id ? pendingInteraction : nil
            return .session(id: id, interaction: interaction)
        case .none:
            return pasteTarget.map(CaptureRoute.paste) ?? .historyOnly
        }
    }
}

enum CaptureCorrelation {
    /// Resolve final backend output to its run. Missing IDs are accepted only
    /// for one-release backend compatibility when ownership is unambiguous.
    static func resolve(requestId: String?, runs: [UUID: CaptureRun]) -> UUID? {
        if let requestId, let id = UUID(uuidString: requestId), runs[id] != nil { return id }
        let pending = runs.values.filter { $0.phase == .awaitingTranscription }
        return pending.count == 1 ? pending[0].id : nil
    }
}
