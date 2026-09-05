import Foundation
import Cocoa
import CoreGraphics

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Agent (foreground turns, dispatched to the codex/OpenCode runtimes)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let DefaultAgentBaseURL = "https://openrouter.ai/api/v1"
let DefaultAgentModel = "anthropic/claude-sonnet-4.5"

/// Writable roots granted to the agent out of the box (VF-59). These are the
/// places the assistant was repeatedly asked to work in and couldn't — the
/// Desktop it was told to organize, the Downloads it was told to save into,
/// Voice Flow's own data it was asked to inspect. Everything outside stays
/// read-only until the user grants it.
let DefaultAgentWorkspaceRoots = [
    "~/repos", "~/Desktop", "~/Downloads", "~/.config/voice-flow",
]

enum AgentActivity: String {
    case idle, thinking, responding, acting
}

enum AgentError: LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No agent API key. Add your OpenRouter key in Settings."
        }
    }
}

// ── Agent Session ───────────────────────────────────────
// Owns the conversation and hands each turn to the selected runtime.

final class AgentSession {
    var onActivityChanged: ((AgentActivity) -> Void)?
    var onAssistantStart: (() -> Void)?
    var onAssistantDelta: ((String) -> Void)?
    var onAssistantDone: ((String) -> Void)?
    var onToolActivity: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onHistoryChanged: (() -> Void)?
    var onEmbeddedOverlayTool: (([String: Any], String) async throws -> AgentToolOutput)?
    var onEmbeddedUserTool: (([String: Any], String) async throws -> AgentToolOutput)?

    /// When false, the computer tool only allows screenshots.
    /// Settings → Assistant → "Computer use".
    var allowControl: Bool { UserSettings.shared.assistantComputerUse }

    private(set) var isRunning = false
    private var interruptRequested = false
    private var activeTask: Task<Void, Never>?
    private var runningSessionId: String?

    private let screenCapture: ScreenCapture
    private let control = ComputerControl()
    private let history: AssistantHistoryStore
    private(set) var currentSessionId: String

    // Runtime adapters emit one normalized event vocabulary. The direct API
    // loop remains only as a one-release fallback while OpenCode is added.
    private let codexRuntime = CodexAgentRuntime()
    private let openCodeRuntime = OpenCodeAgentRuntime()
    private let claudeRuntime = ClaudeCodeAgentRuntime()
    private var codexThreadId: String?
    private var pendingCodexTurn: (
        text: String,
        images: [Data],
        preparation: AssistantTurnPreparation
    )?
    private var pendingOpenCodeTurn: (
        text: String,
        images: [Data],
        preparation: AssistantTurnPreparation
    )?
    private var runningRuntimeKind: AgentRuntimeKind?
    private var runningTurnID: UUID?
    private var pendingSourceContext = ""
    private var sourceTurnAssistant: AssistantDefinition?

    // Screenshot geometry: everything sent to the model uses one fixed size
    // so computer-tool coordinates stay consistent across the session.
    private var imageWidth = 0
    private var imageHeight = 0

    private(set) var activity: AgentActivity = .idle {
        didSet {
            let value = activity
            DispatchQueue.main.async { self.onActivityChanged?(value) }
        }
    }

    init(screenCapture: ScreenCapture, history: AssistantHistoryStore = .shared) {
        self.screenCapture = screenCapture
        self.history = history
        currentSessionId = history.activeSessionId
        loadRuntime(from: history.activeConversation())
        recomputeGeometry()
    }

    @discardableResult
    func reset() -> AssistantConversation {
        interrupt()
        return createConversation()
    }

    var hasConversation: Bool { !history.activeConversation().messages.isEmpty }
    var currentConversation: AssistantConversation { history.activeConversation() }
    var conversations: [AssistantConversation] { history.conversations() }

    var preferredRuntime: AgentRuntimeKind {
        if let runtime = currentConversation.preferredRuntime { return runtime }
        return AgentRuntimeKind.fromBackendSetting(UserSettings.shared.agentBackend)
    }

    /// The adapter for a runtime kind. Codex and Claude Code are CLI
    /// subscriptions; OpenCode is the supervised loopback server.
    private func runtime(for kind: AgentRuntimeKind) -> any AgentRuntime {
        switch kind {
        case .codex: return codexRuntime
        case .opencode: return openCodeRuntime
        case .claude: return claudeRuntime
        }
    }

    /// The model a conversation's next turn uses for a runtime: its own
    /// choice when it made one, else the global default for that runtime.
    func preferredModel(for kind: AgentRuntimeKind, sessionId: String? = nil) -> String {
        let conversation = sessionId.flatMap { history.conversation($0) } ?? currentConversation
        if let chosen = conversation.preferredModels?[kind.rawValue], !chosen.isEmpty { return chosen }
        switch kind {
        case .codex: return UserSettings.shared.codexModel
        case .claude: return UserSettings.shared.claudeCodeModel
        case .opencode: return UserSettings.shared.agentModel
        }
    }

    /// The composer's model choice for one conversation. Allowed mid-turn:
    /// it lands on the next turn.
    /// Every per-conversation model choice for `kind` — the gateway
    /// allowlist must admit them alongside the global and job models.
    func conversationPreferredModels(for kind: AgentRuntimeKind) -> Set<String> {
        Set(history.conversations().compactMap { $0.preferredModels?[kind.rawValue] })
    }

    func setPreferredModel(_ model: String, runtime: AgentRuntimeKind, conversationID: String) {
        history.setPreferredModel(model, runtime: runtime, for: conversationID)
        notifyHistoryChanged()
    }

    @discardableResult
    func setPreferredRuntime(_ runtime: AgentRuntimeKind) -> AssistantConversation? {
        guard !isRunning else { return nil }
        history.setPreferredRuntime(runtime, for: currentSessionId)
        notifyHistoryChanged()
        return history.conversation(currentSessionId)
    }

    // ── Persistent assistant (ticket VF-49) ─────────────
    /// The folder-defined assistant this session embodies: her identity and
    /// instructions compose into the prompt, her memory rides every turn,
    /// and her folder is the working directory of shell turns.
    private(set) var activeAssistant: AssistantDefinition?
#if VOICE_FLOW_QA
    var qaTrustProfile: AgentTrustProfile = .workspace
#endif

    private var foregroundTrustProfile: AgentTrustProfile {
#if VOICE_FLOW_QA
        return qaTrustProfile
#else
        return .workspace
#endif
    }

    func setActiveAssistant(_ assistant: AssistantDefinition?) {
        if let assistant {
            history.assignMissingOwners(
                assistantSlug: assistant.slug, assistantName: assistant.name)
        }
        let owner = history.activeConversation().assistantSlug
            .flatMap { AssistantsStore.shared.assistant(slug: $0) }
        activeAssistant = owner ?? assistant
    }

    /// Route to a different folder assistant: a fresh conversation, so the
    /// new persona composes onto a clean thread instead of inheriting one
    /// primed for somebody else.
    func activateAssistant(_ assistant: AssistantDefinition) {
        guard assistant.slug != activeAssistant?.slug else { return }
        activeAssistant = assistant
        createConversation()
    }

    func refreshAssistantDefinition(_ assistant: AssistantDefinition) {
        guard activeAssistant?.slug == assistant.slug else { return }
        activeAssistant = assistant
        notifyHistoryChanged()
    }

    /// First-turn identity. Tool and file mechanics deliberately live in the
    /// corresponding tool definitions, not in this persona layer.
    private var assistantPersonaBlock: String {
        guard let assistant = activeAssistant else { return "" }
        return "\n\nYou are \(assistant.name).\n\n\(assistant.instructions)"
    }

    /// Every-turn block: her memory as it is on disk right now.
    private var assistantMemoryBlock: String {
        guard let assistant = activeAssistant else { return "" }
        let memory = assistant.coreMemory()
        return "\n\n## Your memory — core.md right now\n" + (memory.isEmpty ? "(empty)" : memory)
    }

    private var assistantSkillBlock: String {
        guard let assistant = activeAssistant else { return "" }
        return (try? AgentSkillStore.promptBlock(for: assistant)) ?? ""
    }

    @discardableResult
    func createConversation(force: Bool = false) -> AssistantConversation {
        let conversation = history.createConversation(
            force: force,
            assistantSlug: activeAssistant?.slug,
            assistantName: activeAssistant?.name)
        currentSessionId = conversation.id
        loadRuntime(from: conversation)
        notifyHistoryChanged()
        return conversation
    }

    @discardableResult
    func createConversation(for assistant: AssistantDefinition) -> AssistantConversation {
        activeAssistant = assistant
        return createConversation(force: true)
    }

    @discardableResult
    func createAutomationConversation(jobID: String,
                                      assistant: AssistantDefinition) -> AssistantConversation {
        let conversation = history.createConversation(
            force: true,
            assistantSlug: assistant.slug,
            assistantName: assistant.name,
            automationJobID: jobID,
            activate: false)
        notifyHistoryChanged()
        return conversation
    }

    @discardableResult
    func reconcileAutomationReferences(
        _ references: [String: Set<String>]
    ) -> [String: Set<String>] {
        let missing = history.reconcileAutomationReferences(references)
        notifyHistoryChanged()
        return missing
    }

    @discardableResult
    func activateConversation(_ id: String) -> AssistantConversation? {
        guard !isRunning, let snapshot = history.conversation(id) else { return nil }
        let owner: AssistantDefinition?
        if let slug = snapshot.assistantSlug {
            guard let resolved = AssistantsStore.shared.assistant(slug: slug) else { return nil }
            owner = resolved
        } else {
            owner = activeAssistant
        }
        guard let conversation = history.activate(id) else { return nil }
        activeAssistant = owner
        currentSessionId = conversation.id
        loadRuntime(from: conversation)
        notifyHistoryChanged()
        return conversation
    }

    @discardableResult
    func moveConversation(_ id: String,
                          to assistant: AssistantDefinition) -> AssistantConversation? {
        guard !isRunning,
              let moved = history.moveConversation(
                id, assistantSlug: assistant.slug, assistantName: assistant.name) else {
            return nil
        }
        if currentSessionId == id {
            activeAssistant = assistant
            loadRuntime(from: moved)
        }
        notifyHistoryChanged()
        return moved
    }

    @discardableResult
    func deleteConversation(_ id: String) -> AssistantConversation? {
        guard !isRunning else { return nil }
        guard let active = history.delete(
            id,
            replacementAssistantSlug: activeAssistant?.slug,
            replacementAssistantName: activeAssistant?.name) else { return nil }
        if let ownerSlug = active.assistantSlug {
            activeAssistant = AssistantsStore.shared.assistant(slug: ownerSlug)
        }
        currentSessionId = active.id
        loadRuntime(from: active)
        notifyHistoryChanged()
        return active
    }

    func conversation(_ id: String) -> AssistantConversation? {
        history.conversation(id)
    }

    @discardableResult
    func completeConversation(_ id: String) -> AssistantConversation? {
        guard let conversation = history.completeConversation(id) else { return nil }
        notifyHistoryChanged()
        return conversation
    }

    @discardableResult
    func reopenConversation(_ id: String) -> AssistantConversation? {
        guard let conversation = history.reopenConversation(id) else { return nil }
        notifyHistoryChanged()
        return conversation
    }

    func markAssistantRepliesSeen(for id: String) {
        history.markAssistantRepliesSeen(for: id)
        notifyHistoryChanged()
    }

    func markCurrentAssistantRepliesSeen() {
        markAssistantRepliesSeen(for: currentSessionId)
    }

    /// UI must describe the authority frozen when this turn began, even if
    /// the Assistant's saved settings are edited while it is running.
    func sourceAccessModeForActiveTurn(conversationID: String) -> AgentSourceAccessMode? {
        guard isRunning, runningSessionId == conversationID else { return nil }
        return sourceTurnAssistant?.sourceAccessMode ?? .standard
    }

    func interrupt() {
        interruptRequested = true
        if let turnID = runningTurnID {
            let runtime = runningRuntimeKind
            Task {
                await SourceReviewRuntime.shared.cancel(turnID: turnID)
                await self.runtime(for: runtime ?? .codex).cancel(turnID: turnID)
            }
        }
        activeTask?.cancel()
    }

    /// Termination needs a joinable form of interrupt so a menu-bar app exit
    /// cannot orphan Codex/OpenCode descendants after AppKit tears down.
    func shutdown() async {
        interruptRequested = true
        let task = activeTask
        if let turnID = runningTurnID {
            await SourceReviewRuntime.shared.cancel(turnID: turnID)
            await runtime(for: runningRuntimeKind ?? .codex).cancel(turnID: turnID)
        }
        task?.cancel()
        await task?.value
        codexRuntime.shutdown()
    }

    private func loadRuntime(from conversation: AssistantConversation) {
        codexThreadId = conversation.codexThreadId
        pendingCodexTurn = nil
        pendingOpenCodeTurn = nil
        runningRuntimeKind = nil
        runningTurnID = nil
    }

    private func notifyHistoryChanged() {
        DispatchQueue.main.async { self.onHistoryChanged?() }
    }

    private func recomputeGeometry() {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = min(1.0, 1440.0 / frame.width)
        imageWidth = Int((frame.width * scale).rounded())
        imageHeight = Int((frame.height * scale).rounded())
        control.imageToScreenScale = frame.width / CGFloat(imageWidth)
    }

    /// Send a user turn (text and/or screenshots) to the selected runtime.
    func send(text: String?, screenshots: [Data]) {
        guard !isRunning else {
            onError?("The agent is still working — stop it first or wait.")
            return
        }
        let selectedRuntime = preferredRuntime
        // Codex and Claude Code use their CLI's subscription. OpenCode's model
        // gateway requires the provider credential already stored in Voice
        // Flow's Keychain.
        let usingCodex = selectedRuntime.usesSubscriptionCLI
        let copiesOnly = activeAssistant?.sourceAccessMode == .reviewCopies
        guard (usingCodex && !copiesOnly) || KeychainStore.shared.loadAgentAPIKey() != nil else {
            let message = AgentError.missingAPIKey.localizedDescription
            history.appendMessage(sessionId: currentSessionId, role: .note, text: message)
            notifyHistoryChanged()
            onError?(message)
            return
        }

        recomputeGeometry()
        interruptRequested = false
        isRunning = true

        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty || !screenshots.isEmpty else {
            isRunning = false
            return
        }
        let sessionId = currentSessionId
        runningSessionId = sessionId
        sourceTurnAssistant = activeAssistant
        let promptText = trimmed.isEmpty ? "(No note — the screenshots are the message.)" : trimmed
        let attachmentNote = Self.attachmentNote(count: screenshots.count)
        let runtimePreparation = history.beginRuntimeTurn(
                sessionId: sessionId, runtime: selectedRuntime,
                text: trimmed, attachmentNote: attachmentNote)
        guard let runtimePreparation else {
            isRunning = false
            runningSessionId = nil
            let message = history.conversation(sessionId)?.turnState == .running
                ? "This conversation is already running in the background."
                : "This conversation is no longer available."
            onError?(message)
            return
        }
        runningRuntimeKind = selectedRuntime
        runningTurnID = UUID()
        notifyHistoryChanged()

        let jpegs = screenshots.compactMap { ImageUtils.resizeExact($0, width: imageWidth, height: imageHeight) }
        if usingCodex {
            pendingCodexTurn = (
                text: promptText,
                images: jpegs,
                preparation: runtimePreparation
            )
        } else {
            pendingOpenCodeTurn = (
                text: promptText,
                images: jpegs,
                preparation: runtimePreparation
            )
        }

        activeTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func finish(_ finalText: String?, finalAlreadyPersisted: Bool = false) {
        let sessionId = runningSessionId
        runningSessionId = nil
        let runtime = runningRuntimeKind
        runningRuntimeKind = nil
        runningTurnID = nil
        isRunning = false
        activeTask = nil
        sourceTurnAssistant = nil
        activity = .idle
        if let sessionId {
            if let finalText, !finalText.isEmpty {
                if !finalAlreadyPersisted {
                    history.appendMessage(sessionId: sessionId, role: .assistant, text: finalText)
                }
            }
            if finalText == nil || finalText?.isEmpty == true {
                if runtime != nil {
                    history.endRuntimeTurnWithoutFinal(
                        sessionId: sessionId, interrupted: interruptRequested)
                } else {
                    history.setTurnState(.idle, for: sessionId)
                }
            } else if !finalAlreadyPersisted {
                history.setTurnState(.idle, for: sessionId)
            }
            notifyHistoryChanged()
        }
        if let finalText, !finalText.isEmpty {
            DispatchQueue.main.async { self.onAssistantDone?(finalText) }
        }
    }

    private func runLoop() async {
        do {
            pendingSourceContext = try AgentSourceContext.freeze(
                sourceIDs: sourceTurnAssistant?.selectedSourceIDs ?? [])
        } catch {
            let message = error.localizedDescription
            recordNote(message)
            DispatchQueue.main.async { self.onError?(message) }
            finish(nil)
            return
        }
        if sourceTurnAssistant?.sourceAccessMode == .reviewCopies {
            await runSourceReviewTurn()
            return
        }
        switch runningRuntimeKind {
        case .opencode: await runOpenCodeTurn()
        case .codex, .claude: await runCLITurn(runningRuntimeKind ?? .codex)
        case nil: finish(nil)
        }
    }

    private func runSourceReviewTurn() async {
        guard let turn = pendingCodexTurn ?? pendingOpenCodeTurn,
              let runtime = runningRuntimeKind,
              let turnID = runningTurnID else { finish(nil); return }
        pendingCodexTurn = nil
        pendingOpenCodeTurn = nil
        let sessionId = runningSessionId ?? currentSessionId
        defer { history.invalidateRuntimeBindingsAfterSourceReview(sessionId: sessionId) }
        let reviewAssistant = sourceTurnAssistant
        let layers = AgentPromptComposer.layers(
            assistant: reviewAssistant, priorMessages: turn.preparation.priorMessages,
            task: turn.text, includeHandoff: true, includeSkillBodies: false,
            sourceContext: pendingSourceContext)
        let request = AgentTurnRequest(
            turnID: turnID, conversationID: sessionId, assistant: reviewAssistant,
            priorMessages: turn.preparation.priorMessages,
            prompt: AgentPromptComposer.compose(layers, includeIdentity: true),
            screenshots: turn.images,
            workingDirectory: reviewAssistant?.directory ?? VoiceFlowPaths.shared.configRoot,
            extraWritableRoots: [], trustProfile: .observe,
            model: AgentModelSelection(provider: "openrouter",
                model: preferredModel(for: .opencode, sessionId: sessionId),
                reasoningEffort: UserSettings.shared.agentReasoningEffort),
            sourceContext: pendingSourceContext, sourceAccessMode: .reviewCopies)
        activity = .thinking
        do {
            let result = try await SourceReviewRuntime.shared.run(request) { [weak self] event in
                guard let self else { return }
                switch event {
                case .activity(let text): DispatchQueue.main.async { self.onToolActivity?(text) }
                case .textDelta(_, let text):
                    self.activity = .responding
                    DispatchQueue.main.async { self.onAssistantStart?(); self.onAssistantDelta?(text) }
                default: break
                }
            }
            history.completeRuntimeTurn(sessionId: sessionId, runtime: runtime,
                text: result.text, runtimeVersion: result.runtimeVersion)
            finish(result.text, finalAlreadyPersisted: true)
        } catch is CancellationError {
            handleInterruption()
        } catch {
            if interruptRequested { handleInterruption(); return }
            let message = error.localizedDescription
            recordNote(message)
            DispatchQueue.main.async { self.onError?(message) }
            finish(nil)
        }
    }

    private static func attachmentNote(count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "📎 1 screenshot"
        default: return "📎 \(count) screenshots"
        }
    }


    private func runOpenCodeTurn() async {
        activity = .thinking
        guard let turn = pendingOpenCodeTurn else {
            let message = "OpenCode turn was not prepared."
            recordNote(message)
            DispatchQueue.main.async { self.onError?(message) }
            finish(nil)
            return
        }
        pendingOpenCodeTurn = nil
        let sessionId = runningSessionId ?? currentSessionId
        let turnID = runningTurnID ?? UUID()
        let workingDirectory = activeAssistant?.directory
            ?? VoiceFlowPaths.shared.directory("assistants/default")
        do {
            if let activeAssistant { _ = try AgentSkillStore.project(for: activeAssistant) }
        } catch {
            let message = error.localizedDescription
            recordNote(message)
            DispatchQueue.main.async { self.onError?(message) }
            finish(nil)
            return
        }
        let layers = AgentPromptComposer.layers(
            assistant: activeAssistant,
            priorMessages: turn.preparation.priorMessages,
            task: turn.text,
            includeHandoff: turn.preparation.requiresFreshSession,
            includeSkillBodies: false, sourceContext: pendingSourceContext)
        let prompt = AgentPromptComposer.compose(
            layers, includeIdentity: turn.preparation.requiresFreshSession)
        let binding = turn.preparation.resumeExternalSessionID.map {
            RuntimeBinding(
                externalSessionID: $0,
                syncedThroughMessageID: turn.preparation.priorContextMessageID,
                state: .clean)
        }
        let request = AgentTurnRequest(
            turnID: turnID, conversationID: sessionId,
            assistant: activeAssistant,
            priorMessages: turn.preparation.priorMessages,
            prompt: prompt, screenshots: turn.images,
            workingDirectory: workingDirectory,
            extraWritableRoots: [], trustProfile: foregroundTrustProfile,
            model: AgentModelSelection(
                provider: "openrouter", model: preferredModel(for: .opencode, sessionId: sessionId),
                reasoningEffort: UserSettings.shared.agentReasoningEffort))

        AgentToolSessionRegistry.shared.prepare(
            turnID: turnID,
            environment: embeddedToolEnvironment(conversationID: sessionId),
            overrides: [
                .computerControl: allowControl ? .allow : .deny,
                .userAsk: .allow,
            ])

        do {
            var startedResponding = false
            let result = try await openCodeRuntime.run(
                request, binding: binding,
                emit: { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .started(let id):
                        self.history.recordRuntimeStarted(
                            sessionId: sessionId, runtime: .opencode,
                            externalSessionID: id,
                            runtimeVersion: nil,
                            fresh: turn.preparation.requiresFreshSession)
                        self.notifyHistoryChanged()
                    case .activity(let label):
                        self.activity = .acting
                        DispatchQueue.main.async { self.onToolActivity?(label) }
                    case .textDelta(_, let piece):
                        if !startedResponding {
                            startedResponding = true
                            self.activity = .responding
                            DispatchQueue.main.async { self.onAssistantStart?() }
                        }
                        DispatchQueue.main.async { self.onAssistantDelta?(piece) }
                    case .permission(let permission):
                        DispatchQueue.main.async {
                            self.onToolActivity?("Permission required: \(permission.title)")
                        }
                    case .usage:
                        break
                    case .completed, .failed, .interrupted:
                        break
                    }
                })
            if !startedResponding && !result.text.isEmpty {
                startedResponding = true
                activity = .responding
                DispatchQueue.main.async {
                    self.onAssistantStart?()
                    self.onAssistantDelta?(result.text)
                }
            }
            history.completeRuntimeTurn(
                sessionId: sessionId, runtime: .opencode,
                text: result.text,
                externalSessionID: result.externalSessionID,
                runtimeVersion: result.runtimeVersion)
            finish(result.text, finalAlreadyPersisted: true)
        } catch is CancellationError {
            handleInterruption()
        } catch {
            if interruptRequested {
                handleInterruption()
                return
            }
            let message = error.localizedDescription
            recordNote(message)
            DispatchQueue.main.async { self.onError?(message) }
            finish(nil)
        }
    }

    // ── Codex turn ──────────────────────────────────────

    /// The persona preamble Codex gets on a thread's first turn; later turns
    /// resume the same thread, so it isn't repeated.
    private var codexPreamble: String {
        """
        You are the assistant inside Voice Flow, a macOS companion app for voice dictation, text-to-speech, \
        and screen capture. The user's words arrive from the app's chat panel, and the plain text you reply \
        with is shown directly back in that panel — that IS the communication channel, already connected. \
        Never use tools, commands, or servers to reach, notify, or "connect to" the user; just answer. \
        Only run shell commands when the user's request itself needs local information (files, processes, \
        git state). The user talks by voice or types; screenshots of their screen may be attached — treat \
        any drawn annotations on them as part of the message. Keep replies concise and plain text, no \
        markdown headings or tables. If something on screen is ambiguous, say what you see and ask one \
        focused question.

        Voice Flow keeps its data under ~/.config/voice-flow/:
        - dictations.json — the user's dictation history, newest first; entries are {text, time, timestamp, destination}; \
        timestamp is the full date-time while time is the preserved display field. "My transcripts" or "my dictations" means this file.
        - ~/.config/tickets/dictation-cursor.json — the shared processing cursor for dictations; processedThrough is the latest handled timestamp. \
        Only kept/inbox dictations after that boundary are unprocessed.
        - captures/<id>/transcript.md — recorded demonstration sessions: spoken narration plus ordered \
        screenshot frames (in frames/ beside it); meta.json has timing. Newest <id> sorts last.
        - messages.json — messages assistant sessions have pushed to the user (time, session, text).
        When the user says to read, summarize, or work from their transcripts or recordings, read these \
        files directly.
        """
    }

    /// Repeated on every turn so threads created under an older access policy
    /// learn the current runtime capabilities when they resume.
    private var codexAccessNote: String {
        """
        Runtime access: shell commands have unrestricted outbound network access and workspace write \
        access. Use installed skills and CLIs for external services when the user's request requires it; \
        do not claim network access is unavailable without trying the relevant command.
        """
    }

    /// Runs one turn through a CLI runtime — Codex or Claude Code. Both take
    /// the same composed prompt, resume their own external session per
    /// conversation, and stream through the shared runtime event vocabulary.
    private func runCLITurn(_ kind: AgentRuntimeKind) async {
        activity = .thinking
        guard let turn = pendingCodexTurn else {
            let message = "\(kind.label) turn was not prepared."
            recordNote(message)
            DispatchQueue.main.async { self.onError?(message) }
            finish(nil)
            return
        }
        pendingCodexTurn = nil

        if kind == .codex { codexThreadId = turn.preparation.resumeExternalSessionID }
        let layers = AgentPromptComposer.layers(
            assistant: activeAssistant,
            priorMessages: turn.preparation.priorMessages,
            task: turn.text,
            includeHandoff: turn.preparation.requiresFreshSession,
            includeSkillBodies: true, sourceContext: pendingSourceContext)
        let composed = AgentPromptComposer.compose(
            layers, includeIdentity: turn.preparation.requiresFreshSession)
        let prompt = (turn.preparation.requiresFreshSession ? codexPreamble + "\n\n" : "")
            + codexAccessNote + "\n\n" + composed
        let sessionId = runningSessionId ?? currentSessionId
        let ticketsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/tickets").path
        let queueDir = VoiceFlowPaths.shared.directory("queue").path
        let turnID = runningTurnID ?? UUID()
        let workingDirectory = activeAssistant?.directory
            ?? FileManager.default.homeDirectoryForCurrentUser
        let request = AgentTurnRequest(
            turnID: turnID,
            conversationID: sessionId,
            assistant: activeAssistant,
            priorMessages: turn.preparation.priorMessages,
            prompt: prompt,
            screenshots: turn.images,
            workingDirectory: workingDirectory,
            extraWritableRoots: activeAssistant == nil ? [] : [ticketsDir, queueDir],
            trustProfile: foregroundTrustProfile,
            model: kind == .claude
                ? AgentModelSelection(
                    provider: "anthropic", model: preferredModel(for: .claude, sessionId: sessionId),
                    reasoningEffort: UserSettings.shared.agentReasoningEffort)
                : AgentModelSelection.codex(
                    model: preferredModel(for: .codex, sessionId: sessionId),
                    reasoningEffort: UserSettings.shared.agentReasoningEffort))
        let resumeBinding = turn.preparation.resumeExternalSessionID.map {
            RuntimeBinding(
                externalSessionID: $0,
                syncedThroughMessageID: turn.preparation.priorContextMessageID,
                state: .clean)
        }

        do {
            var started = false
            let result = try await runtime(for: kind).run(
                request, binding: resumeBinding,
                emit: { [weak self] event in
                    guard let self else { return }
                    switch event {
                    case .started(let id):
                        if kind == .codex { self.codexThreadId = id }
                        self.history.recordRuntimeStarted(
                            sessionId: sessionId, runtime: kind,
                            externalSessionID: id, fresh: turn.preparation.requiresFreshSession)
                        self.notifyHistoryChanged()
                    case .activity(let label):
                        DispatchQueue.main.async { self.onToolActivity?(label) }
                    case .textDelta(_, let piece):
                        if !started {
                            started = true
                            self.activity = .responding
                            DispatchQueue.main.async { self.onAssistantStart?() }
                        }
                        DispatchQueue.main.async { self.onAssistantDelta?(piece) }
                    case .permission, .usage, .completed, .failed, .interrupted:
                        break
                    }
                })
            if !started && !result.text.isEmpty {
                started = true
                activity = .responding
                DispatchQueue.main.async {
                    self.onAssistantStart?()
                    self.onAssistantDelta?(result.text)
                }
            }
            if kind == .codex { codexThreadId = result.externalSessionID ?? codexThreadId }
            history.completeRuntimeTurn(
                sessionId: sessionId, runtime: kind,
                text: result.text,
                externalSessionID: kind == .codex ? codexThreadId : result.externalSessionID,
                runtimeVersion: result.runtimeVersion)
            finish(result.text, finalAlreadyPersisted: true)
        } catch is CancellationError {
            handleInterruption()
        } catch {
            if interruptRequested {
                handleInterruption()
                return
            }
            let message = error.localizedDescription
            recordNote(message)
            DispatchQueue.main.async { self.onError?(message) }
            finish(nil)
        }
    }

    private func canonicalHandoff(_ messages: [AssistantHistoryMessage]) -> String {
        AgentPromptComposer.canonicalHandoff(messages)
    }

    /// The same private Voice Flow tool bridge is reused by durable jobs.
    /// It never enters the public MCP registry; authorization remains scoped
    /// to the concrete OpenCode run by AgentToolSessionRegistry.
    func embeddedToolEnvironment(conversationID: String) -> AgentToolEnvironment {
        AgentToolEnvironment(
            computer: { [weak self] arguments in
                guard let self else { throw AgentToolError.unavailable("Assistant ended") }
                return try await self.executeEmbeddedComputer(arguments)
            },
            context: { [weak self] arguments in
                guard let self else { throw AgentToolError.unavailable("Assistant ended") }
                return try await self.executeEmbeddedContext(arguments)
            },
            overlay: { [weak self] arguments in
                guard let handler = self?.onEmbeddedOverlayTool else {
                    throw AgentToolError.unavailable("overlay bridge is not connected")
                }
                return try await handler(arguments, conversationID)
            },
            user: { [weak self] arguments in
                guard let handler = self?.onEmbeddedUserTool else {
                    throw AgentToolError.unavailable("user bridge is not connected")
                }
                return try await handler(arguments, conversationID)
            },
            queue: { arguments in
                try await NextQueue.toolExecute(arguments)
            })
    }

    private func executeEmbeddedComputer(_ arguments: [String: Any]) async throws -> AgentToolOutput {
        let action = try AgentToolDispatcher.requiredString("action", in: arguments)
        if action == "screenshot" {
            let display = await MainActor.run { DisplayTopology.underMouse ?? DisplayTopology.primary }
            guard let display,
                  let raw = try? await screenCapture.captureScreen(on: display),
                  let shot = CaptureStore.saveShot(raw, on: display) else {
                throw AgentToolError.unavailable("screen recording permission may be missing")
            }
            let cursor = await MainActor.run {
                display.screenshotPoint(forGlobalPoint: NSEvent.mouseLocation)
            }
            return AgentToolOutput(data: [
                "path": shot.path, "width": shot.width, "height": shot.height,
                "display_id": Int(display.id),
                "cursor": [Int(cursor.x.rounded()), Int(cursor.y.rounded())],
                "message": "Read `path` with OpenCode's read tool to see the current screen.",
            ])
        }
        var normalized = arguments
        if normalized["scroll_direction"] == nil, let direction = arguments["direction"] {
            normalized["scroll_direction"] = direction
        }
        if normalized["scroll_amount"] == nil, let amount = arguments["amount"] {
            normalized["scroll_amount"] = amount
        }
        let data = try JSONSerialization.data(withJSONObject: normalized)
        let call = ToolCall(
            id: "embedded-\(UUID().uuidString)", name: "computer",
            arguments: String(data: data, encoding: .utf8) ?? "{}")
        let result = await executeTool(call)
        return AgentToolOutput(data: ["message": result.0])
    }

    private func executeEmbeddedContext(_ arguments: [String: Any]) async throws -> AgentToolOutput {
        let operation = try AgentToolDispatcher.requiredString("operation", in: arguments)
        let limit = min(max((arguments["limit"] as? NSNumber)?.intValue ?? 10, 1), 40)
        switch operation {
        case "latest_capture":
            guard let (directory, meta) = CaptureStore.latestBundle() else {
                return AgentToolOutput(data: ["capture": NSNull(), "message": "No completed captures."])
            }
            return AgentToolOutput(data: ["capture": [
                "id": meta.id, "directory": directory.path,
                "recorded_at": meta.startedAt,
                "duration_seconds": Int(meta.durationSeconds),
                "transcript": String(meta.transcript.prefix(8_000)),
                "frames": meta.frames.prefix(20).map {
                    directory.appendingPathComponent($0.file).path
                },
            ]])
        case "list_captures":
            let captures = CaptureStore.listBundles(limit: limit).map { directory, meta in
                ["id": meta.id, "directory": directory.path,
                 "recorded_at": meta.startedAt,
                 "duration_seconds": Int(meta.durationSeconds),
                 "frame_count": meta.frames.count,
                 "transcript_preview": String(meta.transcript.prefix(240))] as [String: Any]
            }
            return AgentToolOutput(data: ["captures": captures, "next_cursor": NSNull()])
        case "recent_dictations":
            let url = VoiceFlowPaths.shared.file("dictations.json")
            let data = (try? Data(contentsOf: url)) ?? Data("[]".utf8)
            let rows = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
            let bounded = rows.prefix(limit).map { row in
                ["text": String((row["text"] as? String ?? "").prefix(2_000)),
                 "timestamp": row["timestamp"] as? String ?? row["time"] as? String ?? "",
                 "destination": row["destination"] as? String ?? ""]
            }
            return AgentToolOutput(data: ["dictations": Array(bounded), "next_cursor": NSNull()])
        default:
            throw AgentToolError.invalidArguments("unsupported context operation")
        }
    }

    private func handleInterruption() {
        recordNote("Stopped by the user.")
        DispatchQueue.main.async { self.onToolActivity?("Stopped") }
        finish(nil)
    }

    /// A note the app wants kept in the current conversation's transcript
    /// (launch leftovers, permission prompts, embedded-tool reports) — it
    /// renders as a NOTE block in the thread and survives restarts.
    func note(_ text: String) { recordNote(text) }

    private func recordNote(_ text: String) {
        history.appendMessage(sessionId: runningSessionId ?? currentSessionId,
                              role: .note, text: text)
        notifyHistoryChanged()
    }


    private struct ToolCall {
        var id: String
        var name: String
        var arguments: String
    }



    // ── Tool execution ──────────────────────────────────

    /// Returns the text result plus an optional image block (screenshots).
    private func executeTool(_ call: ToolCall) async -> (String, [String: Any]?) {
        guard call.name == "computer" else {
            return ("Unknown tool: \(call.name)", nil)
        }
        let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
        let action = input["action"] as? String ?? ""

        DispatchQueue.main.async { self.onToolActivity?(Self.describeAction(action, input: input)) }

        let controlActions: Set<String> = [
            "left_click", "right_click", "middle_click", "double_click", "triple_click",
            "left_click_drag", "type", "key", "scroll", "mouse_move",
        ]
        if controlActions.contains(action) && !allowControl {
            return ("Computer control is disabled. The user can enable it in Voice Flow Settings → Assistant → Computer use.", nil)
        }

        switch action {
        case "screenshot":
            if let block = await captureForAgent() {
                return ("Screenshot captured — attached as the next image.", block)
            }
            return ("Screenshot failed — screen recording permission may be missing.", nil)

        case "cursor_position":
            let location = control.cursorPositionInImageSpace()
            return ("X=\(Int(location.x)), Y=\(Int(location.y))", nil)

        case "wait":
            let seconds = min((input["duration"] as? Double) ?? 1.0, 5.0)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ("Waited \(String(format: "%.1f", seconds))s.", nil)

        case "mouse_move":
            guard let point = coordinate(from: input) else { return ("Missing coordinate.", nil) }
            control.move(to: point)
            return ("Moved cursor.", nil)

        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            guard let point = coordinate(from: input) else { return ("Missing coordinate.", nil) }
            control.click(action: action, at: point, modifiers: input["modifiers"] as? String)
            return ("Clicked.", nil)

        case "left_click_drag":
            guard let start = coordinate(from: input, key: "start_coordinate"),
                  let end = coordinate(from: input) else {
                return ("Missing coordinates for drag.", nil)
            }
            control.drag(from: start, to: end)
            return ("Dragged.", nil)

        case "type":
            let text = input["text"] as? String ?? ""
            control.typeText(text)
            return ("Typed \(text.count) characters.", nil)

        case "key":
            let combo = input["text"] as? String ?? ""
            if control.pressKeyCombo(combo) {
                return ("Pressed \(combo).", nil)
            }
            return ("Unknown key combination: \(combo)", nil)

        case "scroll":
            guard let point = coordinate(from: input) else { return ("Missing coordinate.", nil) }
            let direction = input["scroll_direction"] as? String ?? "down"
            let amount = input["scroll_amount"] as? Int ?? 3
            control.scroll(at: point, direction: direction, amount: amount)
            return ("Scrolled \(direction).", nil)

        default:
            return ("Unsupported action: \(action)", nil)
        }
    }

    private func coordinate(from input: [String: Any], key: String = "coordinate") -> CGPoint? {
        guard let pair = input[key] as? [Any], pair.count == 2 else { return nil }
        let x = (pair[0] as? Double) ?? Double(pair[0] as? Int ?? -1)
        let y = (pair[1] as? Double) ?? Double(pair[1] as? Int ?? -1)
        guard x >= 0, y >= 0 else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func describeAction(_ action: String, input: [String: Any]) -> String {
        switch action {
        case "screenshot": return "Looking at the screen"
        case "type": return "Typing…"
        case "key": return "Pressing \(input["text"] as? String ?? "keys")"
        case "scroll": return "Scrolling"
        case "wait": return "Waiting"
        case "left_click", "double_click", "triple_click", "right_click", "middle_click": return "Clicking"
        case "left_click_drag": return "Dragging"
        case "mouse_move": return "Moving the cursor"
        case "cursor_position": return "Checking the cursor"
        default: return "Working…"
        }
    }

    // ── Screenshots for the model ───────────────────────

    func captureForAgent() async -> [String: Any]? {
        guard let raw = try? await screenCapture.captureScreen() else { return nil }
        return imageBlock(from: raw)
    }

    private func imageBlock(from raw: Data) -> [String: Any]? {
        guard let jpeg = ImageUtils.resizeExact(raw, width: imageWidth, height: imageHeight) else { return nil }
        return [
            "type": "image_url",
            "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
        ]
    }

}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Computer Control (CGEvent mouse + keyboard synthesis)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class ComputerControl {
    /// Multiply model (image) coordinates by this to get screen points.
    var imageToScreenScale: CGFloat = 1.0

    private func screenPoint(_ imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: imagePoint.x * imageToScreenScale, y: imagePoint.y * imageToScreenScale)
    }

    func cursorPositionInImageSpace() -> CGPoint {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard imageToScreenScale > 0 else { return location }
        return CGPoint(x: location.x / imageToScreenScale, y: location.y / imageToScreenScale)
    }

    func move(to imagePoint: CGPoint) {
        let point = screenPoint(imagePoint)
        post(CGEvent(mouseEventSource: source(), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    }

    func click(action: String, at imagePoint: CGPoint, modifiers: String?) {
        let point = screenPoint(imagePoint)
        let flags = modifierFlags(from: modifiers)

        let (button, down, up): (CGMouseButton, CGEventType, CGEventType)
        switch action {
        case "right_click": (button, down, up) = (.right, .rightMouseDown, .rightMouseUp)
        case "middle_click": (button, down, up) = (.center, .otherMouseDown, .otherMouseUp)
        default: (button, down, up) = (.left, .leftMouseDown, .leftMouseUp)
        }

        let clicks: Int64
        switch action {
        case "double_click": clicks = 2
        case "triple_click": clicks = 3
        default: clicks = 1
        }

        move(to: imagePoint)
        usleep(60_000)
        for clickState in 1...clicks {
            let downEvent = CGEvent(mouseEventSource: source(), mouseType: down, mouseCursorPosition: point, mouseButton: button)
            let upEvent = CGEvent(mouseEventSource: source(), mouseType: up, mouseCursorPosition: point, mouseButton: button)
            downEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
            upEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
            if let flags { downEvent?.flags = flags; upEvent?.flags = flags }
            post(downEvent)
            usleep(30_000)
            post(upEvent)
            usleep(60_000)
        }
    }

    func drag(from startImage: CGPoint, to endImage: CGPoint) {
        let start = screenPoint(startImage)
        let end = screenPoint(endImage)
        post(CGEvent(mouseEventSource: source(), mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left))
        usleep(80_000)
        post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left))
        usleep(80_000)

        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
            usleep(15_000)
        }
        post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
    }

    func scroll(at imagePoint: CGPoint, direction: String, amount: Int) {
        move(to: imagePoint)
        usleep(40_000)
        let lines = Int32(max(1, min(amount, 30)))
        var vertical: Int32 = 0
        var horizontal: Int32 = 0
        switch direction {
        case "up": vertical = lines
        case "down": vertical = -lines
        case "left": horizontal = lines
        case "right": horizontal = -lines
        default: vertical = -lines
        }
        let event = CGEvent(
            scrollWheelEvent2Source: source(),
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        )
        post(event)
    }

    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        // Post unicode strings in small chunks — reliable across layouts.
        let characters = Array(text.utf16)
        var index = 0
        while index < characters.count {
            let chunk = Array(characters[index..<min(index + 16, characters.count)])
            let down = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(down)
            let up = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(up)
            usleep(25_000)
            index += 16
        }
    }

    @discardableResult
    func pressKeyCombo(_ combo: String) -> Bool {
        guard let (keyCode, flags) = parseCombo(combo) else { return false }
        let down = CGEvent(keyboardEventSource: source(), virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source(), virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        post(down)
        usleep(30_000)
        post(up)
        return true
    }

    // ── Internals ───────────────────────────────────────

    private func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    private func modifierFlags(from text: String?) -> CGEventFlags? {
        guard let text, !text.isEmpty else { return nil }
        var flags = CGEventFlags()
        for part in text.lowercased().split(separator: "+") {
            if let flag = Self.modifierMap[String(part)] {
                flags.insert(flag)
            }
        }
        return flags.isEmpty ? nil : flags
    }

    private func parseCombo(_ combo: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = combo
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags = CGEventFlags()
        var baseKey: String?
        for part in parts {
            if let flag = Self.modifierMap[part] {
                flags.insert(flag)
            } else {
                baseKey = part
            }
        }

        // Modifier-only combo (e.g. "cmd") — press the modifier key itself
        if baseKey == nil, parts.count == 1, let modifierKey = Self.modifierKeyCodes[parts[0]] {
            return (modifierKey, [])
        }
        guard let key = baseKey, let keyCode = Self.keyMap[key] else { return nil }
        return (keyCode, flags)
    }

    private static let modifierMap: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand, "meta": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "shift": .maskShift,
        "fn": .maskSecondaryFn, "function": .maskSecondaryFn,
    ]

    private static let modifierKeyCodes: [String: CGKeyCode] = [
        "cmd": 55, "command": 55, "ctrl": 59, "control": 59,
        "alt": 58, "option": 58, "shift": 56, "fn": 63,
    ]

    private static let keyMap: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "equal": 24, "9": 25, "7": 26, "-": 27, "minus": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "comma": 43, "/": 44, "slash": 44, "n": 45, "m": 46,
        ".": 47, "period": 47, "`": 50, "grave": 50,
        "return": 36, "enter": 36, "kp_enter": 76,
        "tab": 48, "space": 49, "spacebar": 49,
        "delete": 51, "backspace": 51, "forward_delete": 117,
        "escape": 53, "esc": 53,
        "home": 115, "end": 119,
        "page_up": 116, "pageup": 116, "pgup": 116,
        "page_down": 121, "pagedown": 121, "pgdn": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}
