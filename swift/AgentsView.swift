import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Agents tab — every agent talking to you, in one place
//  (panel redesign, ticket #15; spec: design/panel-redesign.html)
//
//  Root: a minimal latest-first list — a new-Assistant action, durable local
//  Assistant sessions wearing the VoiceFlow waveform mark, then every
//  connected/ghost MCP session with a plain muted number (≡ the pill picker
//  ⌃⌥1–6). Empty Assistant drafts are hidden. Unread rows read bright.
//  Clicking a row pushes its flat thread over the list: no cards, no
//  timestamps, no repeated names. The composer attaches to an unanswered
//  ask; answers attach beneath (↳); otherwise one composer at the bottom.
//  The pill's ⌃⌥ flow stays the primary notification surface — this tab is
//  the browsable archive of the same per-session stacks.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum AgentSessionKind: Equatable {
    case assistant
    case mcp
}

struct AgentSessionRow: Equatable {
    let id: String
    let kind: AgentSessionKind
    let number: Int?         // ≡ pill picker / ⌃⌥ numbering; nil = consumed
                             // thread kept as history, no ⌃⌥ slot (ticket #17)
    let name: String
    let preview: String      // newest push, one line ("asks: …" when waiting)
    let time: String         // the only timestamps in the whole panel
    let updatedAt: Date
    let owner: String
    let unread: Bool
    let pendingAsk: Bool
    let live: Bool
    /// Evidence of active execution (a local turn in flight). A merely
    /// connected external session is Live, never Running — Now's "Running
    /// now" section must not fill with idle sessions.
    let running: Bool
    let archived: Bool
    /// Consumed thread kept as history (ticket #17) — tagged "completed".
    let completed: Bool
    /// Session died with the stack still active — tagged "ghost".
    let ghost: Bool
}

enum AgentThreadMessageRole {
    case assistant
    case user
    case note
}

struct AgentThreadMessage {
    let id: String
    let at: Date
    let role: AgentThreadMessageRole
    let text: String
    let hint: String?
}

struct AgentThreadDetail {
    let id: AgentsThreadID
    let title: String
    let owner: String
    let state: String
    let messages: [AgentThreadMessage]
    let archived: Bool
    let live: Bool
    /// A blocked question is waiting on the user. Completing the thread
    /// cancels it, so the ✓ action must confirm first instead of acting.
    let pendingAsk: Bool
    let canReply: Bool
    let canSpeak: Bool
    let canComplete: Bool
    let canDelete: Bool
    let claimsContextualFocus: Bool
    let readOnlyReason: String?
    let linkedAutomationCount: Int
    /// Assistant conversations only: which runtime the next turn uses and
    /// whether it may be switched right now; what the current turn is doing;
    /// whether the composer offers "snap the screen and send".
    var runtime: AgentRuntimeKind? = nil
    /// The model this conversation's next turn uses for `runtime` ("" = default).
    var model: String = ""
    var runtimeSwitchable: Bool = false
    var activity: AgentActivity = .idle
    var canSnap: Bool = false
    var sourceReviewOnly: Bool = false
}

struct AgentJobRow: Equatable {
    let id: String
    let name: String
    let preview: String
    let time: String
    let updatedAt: Date
    let assistantName: String
    let assistantSlug: String
    let state: AgentJobState
    let isEnabled: Bool
    let runtime: AgentRuntimeKind
    let trigger: AgentJobTriggerKind
    let modelID: String?
    let prompt: String
    let nextRunAt: Date?
    let intervalSeconds: TimeInterval?
    let dailyTimeMinutes: Int?
    let dailyBudgetUSD: Double
    let spentTodayUSD: Double
    let maxDurationSeconds: TimeInterval
    let maxAttempts: Int
    let hasPendingTrigger: Bool
    let runs: [AgentRunRow]
    var selectedSourceIDs: [String] = []
    var sourceAccessMode: AgentSourceAccessMode = .standard
}

struct AgentRunRow: Equatable {
    let id: String
    let state: AgentRunState
    let startedAt: Date
    let finishedAt: Date?
    let attempt: Int
    let costUSD: Double
    let error: String?
}

struct AgentAutomationDraft {
    let name: String
    let assistantSlug: String
    let runtime: AgentRuntimeKind
    let modelID: String?
    let trigger: AgentJobTriggerKind
    let prompt: String
    let intervalSeconds: TimeInterval?
    let dailyTimeMinutes: Int?
    let dailyBudgetUSD: Double
    let maxDurationSeconds: TimeInterval
    let maxAttempts: Int
    let enabled: Bool
    var selectedSourceIDs: [String] = []
    var sourceAccessMode: AgentSourceAccessMode = .standard
}

struct AgentAutomationDefaults {
    let runtime: AgentRuntimeKind
    let modelID: String?
}

/// One of the three fixed agents the app runs on its own behalf (system
/// agents). Both the list row and its editor read this: they are few and
/// small, so a second round-trip for the detail would buy nothing.
struct AgentSystemAgentRow: Equatable {
    let kind: String
    let name: String
    let purpose: String
    let trigger: String
    let runsOn: String
    let model: String
    let defaultModel: String
    let effort: String
    let effortLabel: String
    let supportsEffort: Bool
    let instructions: String
    let editableInstructions: Bool
    let instructionsNote: String?
    let instructionsContract: String?
    let usesDefaults: Bool
}

struct AgentAssistantRow: Equatable {
    let slug: String
    let name: String
    let description: String
    let isDefault: Bool
    let conversationCount: Int
    let automationCount: Int
    let skillCount: Int
    let attentionCount: Int
    let running: Bool
    let updatedAt: Date?
}

protocol AgentsDataSource: AnyObject {
    func agentDataSourceOptions() -> [SourceSelectionOption]
    func openAgentDataSources()
    func agentSessionRows() -> [AgentSessionRow]
    func agentThreadDetail(for id: AgentsThreadID) -> AgentThreadDetail?
    @discardableResult func activateThread(_ id: AgentsThreadID) -> Bool
    func markThreadSeen(_ id: AgentsThreadID)
    /// Route a typed message through the exact source adapter. Assistant
    /// turns use canonical history; external messages resolve a live ask or
    /// queue for only that session.
    func sendMessage(toThread id: AgentsThreadID, text: String, attachments: [String]) throws
    func speakThread(_ id: AgentsThreadID)
    func completeThread(_ id: AgentsThreadID) throws
    func reopenThread(_ id: AgentsThreadID) throws
    func deleteThread(_ id: AgentsThreadID) throws
    func agentAssistantRows() -> [AgentAssistantRow]
    func agentSystemAgentRows() -> [AgentSystemAgentRow]
    /// nil for a field means "leave as it is"; an empty model or effort means
    /// "back to the shipped default".
    func updateAgentSystemAgent(kind: String, model: String, effort: String?,
                                instructions: String?) throws
    func resetAgentSystemAgent(kind: String) throws
    /// Run the agent's real path once with its saved config and report what
    /// came back — the in-product proof that a retune actually works.
    func testAgentSystemAgent(kind: String, completion: @escaping (String) -> Void)
    func agentJobRows() -> [AgentJobRow]
    func agentAutomationModels() -> [OpenRouterModel]
    /// Catalog refresh behind the editor: calls back on main only when a
    /// network refresh actually happened and produced models.
    func refreshAgentAutomationModels(completion: @escaping ([OpenRouterModel]) -> Void)
    func agentAutomationDefaults() -> AgentAutomationDefaults
    func createAgentAutomation(_ draft: AgentAutomationDraft) throws -> String
    func updateAgentAutomation(id: String, draft: AgentAutomationDraft) throws
    func duplicateAgentAutomation(id: String) throws -> String
    func deleteAgentAutomation(id: String) throws
    func runAgentJob(_ jobId: String)
    func cancelAgentJob(_ jobId: String)
    func setAgentJob(_ jobId: String, enabled: Bool)
    func assistantWorkspace(slug: String) throws -> AssistantWorkspaceSnapshot
    func createAgentAssistant(_ draft: AssistantDraft) throws -> String
    func duplicateAgentAssistant(slug: String, name: String) throws -> String
    func updateAgentAssistant(slug: String, draft: AssistantDraft,
                              expectedRevision: String) throws
    func updateAgentAssistantMemory(slug: String, kind: String, content: String,
                                    expectedRevision: String) throws -> AgentMemoryDocument
    func createAgentAssistantConversation(slug: String) throws -> String
    func deleteAgentAssistant(slug: String) throws -> AssistantDeletionOutcome
}

extension AgentsDataSource {
    func agentDataSourceOptions() -> [SourceSelectionOption] { [] }
    func openAgentDataSources() {}
}

final class AgentsView: NSView, NSTextFieldDelegate {
    weak var dataSource: AgentsDataSource?
    /// Local Assistant sessions share this list but keep their native chat
    /// lifecycle instead of being forced through MCP push semantics.
    var onNewAssistant: (() -> Void)?
    var onOpenAssistantSession: ((String) -> Void)?
    /// Preferred Agents content height. ChatPanel adds its shared chrome and
    /// clamps the whole panel to its 520pt maximum.
    var onPreferredHeightChanged: ((CGFloat) -> Void)?
    /// A concrete session row was chosen. ChatPanel/AppDelegate use this to
    /// align visible conversation focus with overlay/picker targeting.
    var onOpenSession: ((String) -> Void)?
    /// Fired after every rebuild — the mode (list, thread, form…) may have
    /// changed and the panel's chrome scopes itself to what is showing.
    var onModeChanged: (() -> Void)?
    /// Assistant-thread controls: snap-and-send, stop the running turn,
    /// switch the runtime for this conversation.
    var onSnap: ((AgentsThreadID) -> Void)?
    var onStop: ((AgentsThreadID) -> Void)?
    var onSelectAssistantRuntime: ((AgentRuntimeKind, AgentsThreadID) -> Void)?
    /// The effort popup writes the one shared reasoning-effort setting.
    var onSelectReasoningEffort: ((String) -> Void)?
    /// The access popup sets the capability dial (run commands, control screen).
    var onSelectAccessMode: ((AgentCapabilityDial.AccessMode) -> Void)?
    /// The model popup sets this conversation's model for the runtime ("" = default).
    var onSelectModel: ((AgentRuntimeKind, String, AgentsThreadID) -> Void)?
    /// The mic button: start (or stop) a dictation into this thread.
    var onMicToggle: ((AgentsThreadID) -> Void)?

    private enum Mode: Equatable {
        case destination(AgentsDestination)
        case search
        case thread(AgentsThreadID)
        case job(String)
        case automationCreate
        case automationEdit(String)
        case assistantWorkspace(String, AssistantWorkspaceTab)
        case assistantCreate
        case systemAgent(String)
    }
    private enum AutomationFilter: Int, CaseIterable {
        case all
        case attention
        case active
        case ready
        case disabled

        var label: String {
            switch self {
            case .all: return "All"
            case .attention: return "Needs"
            case .active: return "Active"
            case .ready: return "Ready"
            case .disabled: return "Off"
            }
        }
    }
    private struct AutomationFormValues {
        let name: String
        let instructions: String
        let assistantSlug: String?
        let runtime: String?
        let trigger: String?
        let model: String
        let interval: String
        let dailyTime: String
        let budget: String
        let duration: String
        let attempts: String
        var selectedSourceIDs: [String] = []
        var sourceAccessMode: AgentSourceAccessMode = .standard
    }
    private enum AssistantWorkspaceTab: String, CaseIterable {
        case overview = "Overview"
        case conversations = "Conversations"
        case memory = "Memory & Skills"
        case settings = "Settings"
    }
    private var mode: Mode = .destination(.now)
    /// Everything a read surface (destination, thread, search) renders from.
    /// refresh() is called from ~20 sites, often several times per event,
    /// and every call used to tear down and rebuild the whole hierarchy.
    /// Equal inputs mean an identical screen, so the rebuild is skipped.
    private struct RefreshInputs: Equatable {
        let mode: Mode
        let sessions: [AgentSessionRow]
        let jobs: [AgentJobRow]
        let assistants: [AgentAssistantRow]
        let system: [AgentSystemAgentRow]
        let threadFilter: AgentsThreadFilter
        let searchQuery: String
        let streamingThreads: [String]
        let sourceReviewOnly: Bool?
    }
    private var lastRefreshInputs: RefreshInputs?
    private var currentDestination: AgentsDestination = .now
    private var threadFilter: AgentsThreadFilter = .open

    var openSessionId: String? {
        if case .thread(let id) = mode, id.source == .mcp,
           dataSource?.agentThreadDetail(for: id)?.claimsContextualFocus == true {
            return id.value
        }
        return nil
    }

    var openThreadID: AgentsThreadID? {
        if case .thread(let id) = mode { return id }
        return nil
    }

    var openAssistantThreadClaimsFocus: Bool {
        guard case .thread(let id) = mode, id.source == .assistant else { return false }
        return dataSource?.agentThreadDetail(for: id)?.claimsContextualFocus == true
    }

    private var contentStack: NSView!          // flipped document view
    private var scrollView: NSScrollView!
    /// The composer lives here, pinned under the thread, never inside the
    /// scrolling content — the way a session bar stays put.
    private var composerHost: NSView!
    private var composerHostHeight: NSLayoutConstraint!
    /// The open thread's header (‹ title · state · ✓ 🔊 🗑) lives here,
    /// fixed above the scrolling messages, matching the pinned bar below.
    private var headerHost: NSView!
    private var headerHostHeight: NSLayoutConstraint!
    private var navigationBar: NSView!
    private var workspaceNavigation = false
    private var navigationHeight: NSLayoutConstraint!
    private var contentTop: NSLayoutConstraint!
    private var workspaceCombinedSetup = false
    var onWorkspaceOriginBack: (() -> Void)?
    private var workspaceExternalOrigin: AgentsObjectID?

    func showSourceConsumer(_ object: AgentsObjectID) {
        workspaceExternalOrigin = object
        pushedOrigin = nil
        inlineError = nil
        switch object {
        case .assistant(let slug):
            currentDestination = .assistants
            mode = .assistantWorkspace(slug, .settings)
        case .automation(let id):
            currentDestination = .automations
            mode = .automationEdit(id)
        case .thread(let id):
            currentDestination = .threads
            mode = .thread(id)
        }
        rebuild()
    }

    private var workspaceRoutes: [String: Mode] = [:]
    private enum WorkspaceDraftValue: Equatable {
        case text(String), choice(String), checked(Bool)
    }
    private struct WorkspaceDraft {
        var changes: [String: WorkspaceDraftValue]
        var revision: String?
    }
    private struct WorkspaceForm {
        let key: String
        let controls: [String: NSView]
        var baseline: [String: WorkspaceDraftValue]
        var revision: String?
    }
    private struct WorkspaceFocus {
        let control: String
        let selection: NSRange?
    }
    private var workspaceDrafts: [String: WorkspaceDraft] = [:]
    private var renderedWorkspaceForms: [WorkspaceForm] = []
    private var renderedWorkspaceMode: Mode?

    private func workspaceDescendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + workspaceDescendants($0) }
    }

    private func workspaceValues(_ controls: [String: NSView]) -> [String: WorkspaceDraftValue] {
        controls.compactMapValues { control in
            if let popup = control as? NSPopUpButton {
                return .choice(popup.selectedItem?.representedObject as? String ?? popup.titleOfSelectedItem ?? "")
            }
            if let field = control as? NSTextField { return .text(field.stringValue) }
            if let editor = control as? NSTextView { return .text(editor.string) }
            if let button = control as? NSButton { return .checked(button.state == .on) }
            return nil
        }
    }

    /// Keep only actual edits. A clean form must be able to reveal changes
    /// made by an agent or another editor instead of restoring an old copy.
    private func captureWorkspaceDrafts() {
        for form in renderedWorkspaceForms {
            let changes = workspaceValues(form.controls).filter { form.baseline[$0.key] != $0.value }
            workspaceDrafts[form.key] = changes.isEmpty ? nil
                : WorkspaceDraft(changes: changes, revision: form.revision)
        }
    }

    /// Saving one section cannot discard another section's unsaved work.
    /// Updating its baseline also prevents rebuild from restashing the save.
    private func clearWorkspaceDraft(_ key: String) {
        workspaceDrafts[key] = nil
        for index in renderedWorkspaceForms.indices where renderedWorkspaceForms[index].key == key {
            renderedWorkspaceForms[index].baseline = workspaceValues(renderedWorkspaceForms[index].controls)
        }
    }

    private func workspaceForm(_ key: String, revision: String? = nil,
                               controls entries: [(String, NSView?, String)]) -> WorkspaceForm {
        var controls: [String: NSView] = [:]
        for (id, control, label) in entries {
            guard let control else { continue }
            controls[id] = control
            control.identifier = NSUserInterfaceItemIdentifier(id)
            control.setAccessibilityLabel(label)
        }
        return WorkspaceForm(key: key, controls: controls, baseline: workspaceValues(controls), revision: revision)
    }

    private func sourceFormControls(_ selection: SourceSelectionView?) -> [(String, NSView?, String)] {
        guard let selection else { return [] }
        return workspaceDescendants(selection).compactMap { view in
            guard view is NSButton, let id = view.identifier?.rawValue else { return nil }
            return (id, view, view.accessibilityLabel() ?? id)
        }
    }

    private func currentWorkspaceForms() -> [WorkspaceForm] {
        switch mode {
        case .assistantCreate:
            return [workspaceForm("assistant:create", controls: [
                ("assistant-name", assistantNameField, "Assistant name"),
                ("assistant-description", assistantDescriptionField, "Assistant description"),
                ("assistant-instructions", assistantInstructionsView, "Assistant instructions")])]
        case .assistantWorkspace(let slug, .settings):
            return [workspaceForm("assistant:\(slug):settings", revision: assistantSettingsRevision, controls: [
                ("assistant-name", assistantNameField, "Assistant name"),
                ("assistant-description", assistantDescriptionField, "Assistant description"),
                ("assistant-voice", assistantVoiceField, "Assistant reply voice"),
                ("assistant-instructions", assistantInstructionsView, "Assistant instructions")]
                + sourceFormControls(assistantSources))]
        case .assistantWorkspace(let slug, .memory):
            var forms = [workspaceForm("assistant:\(slug):skills", revision: assistantSkillsRevision,
                controls: assistantSkillButtons.sorted { $0.key < $1.key }.map {
                    ("assistant-skill-\($0.key)", $0.value, "Skill: \($0.key)") })]
            if assistantMemoryView?.isEditable == true {
                forms.append(workspaceForm("assistant:\(slug):memory:\(assistantMemoryKind)",
                    revision: assistantMemoryRevision, controls: [
                        ("assistant-memory-\(assistantMemoryKind)", assistantMemoryView, "\(assistantMemoryKind.capitalized) memory")]))
            }
            return forms
        case .systemAgent(let kind):
            return [workspaceForm("system:\(kind)", controls: [
                ("system-model", systemAgentModelField, "System agent model"),
                ("system-effort", systemAgentEffortPopUp, "System agent reasoning effort"),
                ("system-instructions", systemAgentInstructionsView, "System agent instructions")])]
        case .automationCreate, .automationEdit:
            let key: String
            if case .automationEdit(let id) = mode { key = "automation:\(id)" } else { key = "automation:create" }
            return [workspaceForm(key, controls: [
                ("automation-name", automationNameField, "Automation name"),
                ("automation-instructions", automationInstructionsView, "Automation instructions"),
                ("automation-assistant", automationAssistantPopUp, "Automation Assistant"),
                ("automation-runtime", automationRuntimePopUp, "Automation runtime"),
                ("automation-trigger", automationTriggerPopUp, "Automation trigger"),
                ("automation-model", automationModelCombo, "OpenRouter model"),
                ("automation-interval", automationIntervalField, "Automation interval in minutes"),
                ("automation-daily-time", automationDailyTimeField, "Automation daily run time (HH:MM)"),
                ("automation-budget", automationBudgetField, "Daily budget in dollars"),
                ("automation-duration", automationDurationField, "Maximum runtime in minutes"),
                ("automation-attempts", automationAttemptsField, "Maximum attempts")]
                + sourceFormControls(automationSources))]
        default: return []
        }
    }

    private func restoreWorkspaceDrafts() {
        renderedWorkspaceForms = currentWorkspaceForms()
        for index in renderedWorkspaceForms.indices {
            let form = renderedWorkspaceForms[index]
            guard let draft = workspaceDrafts[form.key] else { continue }
            for (id, value) in draft.changes {
                guard let control = form.controls[id] else { continue }
                switch value {
                case .text(let text):
                    (control as? NSTextField)?.stringValue = text
                    (control as? NSTextView)?.string = text
                case .choice(let choice):
                    guard let popup = control as? NSPopUpButton else { continue }
                    if let item = popup.itemArray.first(where: { ($0.representedObject as? String ?? $0.title) == choice }) {
                        popup.select(item)
                    }
                case .checked(let checked):
                    if let button = control as? NSButton, button.isEnabled { button.state = checked ? .on : .off }
                }
            }
            renderedWorkspaceForms[index].revision = draft.revision
            if case .assistantWorkspace(_, .settings) = mode { assistantSettingsRevision = draft.revision }
            if case .assistantWorkspace(let slug, .memory) = mode {
                if form.key == "assistant:\(slug):skills" { assistantSkillsRevision = draft.revision }
                else { assistantMemoryRevision = draft.revision }
            }
        }
        // Programmatic popup selection does not send its action. Reconcile
        // explanatory copy and enabled fields with the values just restored.
        for selection in [assistantSources, automationSources].compactMap({ $0 }) {
            selection.select(ids: selection.selectedIDs, mode: selection.selectedMode)
        }
        updateAutomationFormAvailability()
    }

    private func workspaceFocus() -> WorkspaceFocus? {
        guard let responder = window?.firstResponder else { return nil }
        for form in renderedWorkspaceForms {
            for (id, control) in form.controls {
                if let field = control as? NSTextField, responder === field.currentEditor() {
                    return WorkspaceFocus(control: id, selection: (field.currentEditor() as? NSTextView)?.selectedRange())
                }
                if responder === control {
                    return WorkspaceFocus(control: id, selection: (control as? NSTextView)?.selectedRange())
                }
            }
        }
        return nil
    }

    private func restoreWorkspaceFocus(_ focus: WorkspaceFocus?) {
        guard let focus, let control = renderedWorkspaceForms.compactMap({ $0.controls[focus.control] }).first,
              window?.makeFirstResponder(control) == true else { return }
        let editor = (control as? NSTextView) ?? ((control as? NSTextField)?.currentEditor() as? NSTextView)
        if let editor, let selection = focus.selection {
            let length = (editor.string as NSString).length
            let location = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        }
    }


    var workspaceDestination: WorkspaceDestination {
        switch mode {
        case .assistantWorkspace, .assistantCreate, .systemAgent: return .assistants
        case .job, .automationCreate, .automationEdit: return .automations
        case .thread: return currentDestination == .now ? .now : .threads
        default:
            switch currentDestination {
            case .now: return .now
            case .threads: return .threads
            case .assistants: return .assistants
            case .automations: return .automations
            }
        }
    }

    var workspaceAttentionCount: Int { nowSnapshot().attentionCount }

    func useWorkspaceNavigation() {
        workspaceNavigation = true
        navigationBar.isHidden = true
        // Remove the old strip's fixed-height children before collapsing its
        // container; hidden NSViews still participate in Auto Layout.
        navigationBar.subviews.forEach { $0.removeFromSuperview() }
        navigationHeight.constant = 0
        contentTop.constant = 0
        rebuild()
    }

    /// Sidebar hops retain the selected object in each workspace section.
    func showWorkspaceRoot(_ destination: AgentsDestination) {
        workspaceExternalOrigin = nil
        let previous = workspaceDestination.rawValue
        workspaceRoutes[previous] = mode
        stashComposerDraft()
        workspaceCombinedSetup = false
        currentDestination = destination
        let key: String
        switch destination {
        case .now: key = "now"
        case .threads: key = "threads"
        case .assistants: key = "assistants"
        case .automations: key = "automations"
        }
        // Reselecting the active section returns to its root; returning from
        // another section restores its current detail.
        mode = previous == key ? .destination(destination)
            : workspaceRoutes[key] ?? .destination(destination)
        pushedOrigin = nil
        inlineError = nil
        threadInlineError = nil
        rebuild()
    }

    private var navigationButtons: [AgentsDestination: NSButton] = [:]
    private var navigationBadges: [AgentsDestination: NSTextField] = [:]
    private var navigationUnderlines: [AgentsDestination: NSView] = [:]
    private var searchButton: NSButton!
    private var searchField: NSTextField?
    private var searchQuery = ""
    private var automationSearchField: NSTextField?
    private var automationSearchQuery = ""
    private var automationFilter: AutomationFilter = .all
    private var composerField: ComposerView?
    private var composerThreadID: AgentsThreadID?
    private weak var attachPicker: NSOpenPanel?
    private var automationNameField: NSTextField?
    private var automationInstructionsView: NSTextView?
    private var automationAssistantPopUp: NSPopUpButton?
    private var automationRuntimePopUp: NSPopUpButton?
    private var automationTriggerPopUp: NSPopUpButton?
    private var automationModelCombo: OpenRouterModelComboBox?
    private var automationIntervalField: NSTextField?
    private var automationDailyTimeField: NSTextField?
    private var automationBudgetField: NSTextField?
    private var automationDurationField: NSTextField?
    private var automationAttemptsField: NSTextField?
    private var automationDeleteConfirmationID: String?
    private var assistantNameField: NSTextField?
    private var assistantDescriptionField: NSTextField?
    private var assistantVoiceField: NSTextField?
    private var assistantInstructionsView: NSTextView?
    private var assistantMemoryView: NSTextView?
    private var assistantMemoryKind = "core"
    private var systemAgentModelField: NSTextField?
    private var systemAgentEffortPopUp: NSPopUpButton?
    private var systemAgentInstructionsView: NSTextView?
    private var systemAgentTestResult: String?
    private var systemAgentTestRunning = false
    private var assistantMemoryRevision: String?
    private var assistantSettingsRevision: String?
    private var assistantSkillsRevision: String?
    private var assistantSkillButtons: [String: NSButton] = [:]
    private var assistantSources: SourceSelectionView?
    private var automationSources: SourceSelectionView?
    private var assistantDeleteConfirmationSlug: String?
    private var threadDeleteConfirmationID: AgentsThreadID?
    private var threadCompleteConfirmationID: AgentsThreadID?
    private var threadDrafts: [AgentsThreadID: String] = [:]
    /// Attached image paths, kept per thread across rebuilds like the draft.
    private var threadAttachments: [AgentsThreadID: [String]] = [:]
    /// A dictation is going into the open thread; the composer is rebuilt
    /// on every history change, so the flag lives here.
    private var recordingActive = false
    /// Model lists are read from disk / the catalog; a rebuild per streamed
    /// message must not re-read them.
    private var modelChoicesCache: [AgentRuntimeKind: (at: Date, choices: [(value: String, label: String)])] = [:]
    private var claudeModelsObserver: NSObjectProtocol?
    private var threadInlineError: String?
    private var pushedOrigin: Mode?
    private var assistantThreadStreams: [String: String] = [:]
    private weak var assistantThreadStreamingLabel: NSTextField?
    /// Message rows of the open thread, keyed by message id. A thread
    /// refresh (new push, seen-state change, navigation back onto it) used
    /// to re-create every row — label, wrapping body, divider, constraints —
    /// which is the lag on long threads. Rows now persist across rebuilds
    /// and are updated in place when their text changes; only new messages
    /// get new views. Scoped to one thread; cleared when it changes.
    private var threadRowCache: [String: ThreadMessageRow] = [:]
    private var threadRowCacheThread: AgentsThreadID?

    private final class ThreadMessageRow: NSView {
        let role = NSTextField(labelWithString: "")
        let body = NSTextField(wrappingLabelWithString: "")
        let dividerHeight: NSLayoutConstraint
        var contentKey = ""

        init() {
            let divider = NSView()
            dividerHeight = divider.heightAnchor.constraint(equalToConstant: 1)
            super.init(frame: .zero)
            role.font = .systemFont(ofSize: 9.5, weight: .semibold)
            body.font = .systemFont(ofSize: 12.5)
            body.maximumNumberOfLines = 0
            body.isSelectable = true
            divider.wantsLayer = true
            divider.layer?.backgroundColor = Theme.border.cgColor
            for view in [role, body, divider] {
                view.translatesAutoresizingMaskIntoConstraints = false
                addSubview(view)
            }
            NSLayoutConstraint.activate([
                role.topAnchor.constraint(equalTo: topAnchor, constant: 9),
                role.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                body.topAnchor.constraint(equalTo: role.bottomAnchor, constant: 4),
                body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
                divider.leadingAnchor.constraint(equalTo: leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: trailingAnchor),
                divider.bottomAnchor.constraint(equalTo: bottomAnchor),
                dividerHeight,
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        func apply(roleText: String, roleColor: NSColor, bodyText: String, bodyColor: NSColor, key: String) {
            guard key != contentKey else { return }
            contentKey = key
            role.stringValue = roleText
            role.textColor = roleColor
            body.stringValue = bodyText
            body.textColor = bodyColor
        }
    }
    /// Live turn state for the open assistant thread — updated in place
    /// (no rebuild) as the agent thinks, acts, and replies.
    private var assistantActivity: AgentActivity = .idle
    private var assistantActivityDetail: String?
    /// A turn tears the composer down (canReply is false while it runs) and
    /// rebuilds it when the reply lands; the caret must come back with it.
    private var composerFocusPending = false
    private var transientNoteLabel: NSTextField?
    private var transientNoteTimer: Timer?
    private var inlineError: String?
    private weak var inlineFormErrorView: NSTextField?
    private var renderedInlineFormError: String?
    private var revealInlineFormError = false
    private var scrollObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupUI()
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let claudeModelsObserver { NotificationCenter.default.removeObserver(claudeModelsObserver) }
    }

    private func setupUI() {
        contentStack = FlippedView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = contentStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        claudeModelsObserver = NotificationCenter.default.addObserver(
            forName: ClaudeModelCatalog.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.modelChoicesCache[.claude] = nil
            if case .thread = self.mode { self.rebuild() }
        }
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverStatesForPointer()
        }

        navigationBar = buildNavigationBar()
        composerHost = NSView()
        composerHost.translatesAutoresizingMaskIntoConstraints = false
        headerHost = NSView()
        headerHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(navigationBar)
        addSubview(headerHost)
        addSubview(scrollView)
        addSubview(composerHost)
        navigationHeight = navigationBar.heightAnchor.constraint(equalToConstant: 36)
        contentTop = headerHost.topAnchor.constraint(equalTo: navigationBar.bottomAnchor, constant: 2)
        headerHostHeight = headerHost.heightAnchor.constraint(equalToConstant: 0)
        composerHostHeight = composerHost.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            navigationBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            navigationBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            navigationHeight,
            contentTop,
            headerHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            headerHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            headerHostHeight,
            scrollView.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: composerHost.topAnchor, constant: -8),
            composerHost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            composerHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            composerHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            composerHostHeight,
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    /// Put the thread's composer in the pinned host (replacing any previous
    /// one) and let the host size to it.
    private func installComposer(_ composer: ComposerView) {
        guard composer.superview !== composerHost else { return }
        composerHost.subviews.forEach { $0.removeFromSuperview() }
        composer.translatesAutoresizingMaskIntoConstraints = false
        composerHost.addSubview(composer)
        composerHostHeight.isActive = false
        NSLayoutConstraint.activate([
            composer.topAnchor.constraint(equalTo: composerHost.topAnchor),
            composer.bottomAnchor.constraint(equalTo: composerHost.bottomAnchor),
            composer.leadingAnchor.constraint(equalTo: composerHost.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: composerHost.trailingAnchor),
        ])
    }

    private func clearComposerHost() {
        composerHost.subviews.forEach { $0.removeFromSuperview() }
        composerHostHeight.isActive = true
    }

    private func installThreadHeader(_ header: NSView) {
        headerHost.subviews.forEach { $0.removeFromSuperview() }
        header.translatesAutoresizingMaskIntoConstraints = false
        headerHost.addSubview(header)
        headerHostHeight.isActive = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headerHost.topAnchor),
            header.bottomAnchor.constraint(equalTo: headerHost.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: headerHost.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: headerHost.trailingAnchor),
        ])
    }

    private func clearHeaderHost() {
        headerHost.subviews.forEach { $0.removeFromSuperview() }
        headerHostHeight.isActive = true
    }

    private func buildNavigationBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        // The mock spreads the destinations evenly across the full width;
        // .fill dumped all the slack into one gap.
        stack.distribution = .equalCentering
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        for destination in AgentsDestination.navigation {
            let item = NSView()
            let button = NSButton(
                title: destination.label, target: self,
                action: #selector(destinationTapped(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.identifier = NSUserInterfaceItemIdentifier(destination.rawValue)
            button.setAccessibilityLabel("Open \(destination.label)")
            navigationButtons[destination] = button

            let badge = NSTextField(labelWithString: "")
            badge.font = .systemFont(ofSize: 10.5, weight: .semibold)
            badge.textColor = Theme.accent
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = Theme.cardHover.cgColor
            badge.layer?.cornerRadius = 7
            badge.isHidden = true
            navigationBadges[destination] = badge

            let underline = NSView()
            underline.wantsLayer = true
            underline.layer?.backgroundColor = Theme.accent.cgColor
            underline.layer?.cornerRadius = 1
            underline.isHidden = true
            navigationUnderlines[destination] = underline

            // The visible label is small; the hit target must not be. An
            // invisible overlay button spans the whole 44pt item, so the
            // label, badge, underline, and surrounding air all take the tap.
            let hitArea = NSButton(title: "", target: self,
                                   action: #selector(destinationTapped(_:)))
            hitArea.isBordered = false
            hitArea.isTransparent = true
            hitArea.identifier = NSUserInterfaceItemIdentifier(destination.rawValue)
            hitArea.setAccessibilityElement(false)
            for subview in [button, badge, underline, hitArea] {
                subview.translatesAutoresizingMaskIntoConstraints = false
                item.addSubview(subview)
            }
            NSLayoutConstraint.activate([
                item.heightAnchor.constraint(equalToConstant: 44),
                button.leadingAnchor.constraint(equalTo: item.leadingAnchor),
                button.centerYAnchor.constraint(equalTo: item.centerYAnchor, constant: -3),
                badge.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 3),
                badge.trailingAnchor.constraint(equalTo: item.trailingAnchor),
                badge.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
                badge.heightAnchor.constraint(equalToConstant: 15),
                underline.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                underline.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                underline.heightAnchor.constraint(equalToConstant: 2),
                underline.bottomAnchor.constraint(equalTo: item.bottomAnchor, constant: -4),
                hitArea.leadingAnchor.constraint(equalTo: item.leadingAnchor, constant: -6),
                hitArea.trailingAnchor.constraint(equalTo: item.trailingAnchor, constant: 6),
                hitArea.topAnchor.constraint(equalTo: item.topAnchor),
                hitArea.bottomAnchor.constraint(equalTo: item.bottomAnchor),
            ])
            stack.addArrangedSubview(item)
        }

        searchButton = NSButton(
            image: NSImage(systemSymbolName: "magnifyingglass",
                           accessibilityDescription: "Search agents") ?? NSImage(),
            target: self, action: #selector(searchTapped))
        searchButton.isBordered = false
        searchButton.contentTintColor = Theme.text3
        searchButton.toolTip = "Search assistants, automations, and threads"
        searchButton.setAccessibilityLabel("Search agents")
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        searchButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        searchButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(searchButton)

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -6),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return bar
    }

    // ── Public surface ──────────────────────────────────

    func showList() {
        currentDestination = .now
        mode = .destination(.now)
        rebuild()
    }

    @discardableResult
    func handleMissionControlCommand(_ key: String) -> Bool {
        if let index = Int(key), (1...AgentsDestination.navigation.count).contains(index) {
            let destination = AgentsDestination.navigation[index - 1]
            workspaceCombinedSetup = destination == .assistants
            currentDestination = destination
            mode = .destination(destination)
            pushedOrigin = nil
            threadInlineError = nil
            inlineError = nil
            rebuild()
            return true
        }
        if key.lowercased() == "k" {
            if case .search = mode {
                searchField?.window?.makeFirstResponder(searchField)
            } else {
                mode = .search
                rebuild()
            }
            return true
        }
        if key == "[" {
            return handleMissionControlEscape()
        }
        return false
    }

    /// Search/detail consumes Escape before the panel's ordinary dismissal.
    /// Root destinations deliberately return false so the global safety path
    /// can close the panel exactly as before.
    @discardableResult
    func handleMissionControlEscape() -> Bool {
        if threadDeleteConfirmationID != nil || threadCompleteConfirmationID != nil {
            threadDeleteConfirmationID = nil
            threadCompleteConfirmationID = nil
            threadInlineError = nil
            rebuild()
            return true
        }
        switch mode {
        case .destination:
            return false
        case .search, .thread, .job, .automationCreate, .automationEdit,
             .assistantWorkspace, .assistantCreate, .systemAgent:
            backTapped()
            return true
        }
    }

#if VOICE_FLOW_QA
    func qaNavigate(destination: String, automationAction: String?, jobID: String?,
                    threadSource: String?, threadID: String?,
                    threadFilter: String?, systemAgent: String? = nil) -> Bool {
        if destination == "assistants", let systemAgent {
            currentDestination = .assistants
            mode = .systemAgent(systemAgent)
            inlineError = nil
            systemAgentTestResult = nil
            rebuild()
            return true
        }
        if destination == "automations" {
            currentDestination = .automations
            if automationAction == "new" {
                mode = .automationCreate
            } else if automationAction == "edit", let jobID {
                mode = .automationEdit(jobID)
            } else if let jobID {
                mode = .job(jobID)
            } else {
                mode = .destination(.automations)
            }
            rebuild()
            return true
        }
        if destination == "threads" {
            currentDestination = .threads
            if let threadFilter,
               let index = AgentsThreadFilter.allCases.firstIndex(where: {
                   $0.label.lowercased() == threadFilter.lowercased()
               }) {
                self.threadFilter = AgentsThreadFilter(rawValue: index) ?? .open
            }
            if let threadID, let rawSource = threadSource,
               let source = AgentsThreadSource(rawValue: rawSource) {
                openThread(AgentsThreadID(source: source, value: threadID))
            } else {
                mode = .destination(.threads)
                rebuild()
            }
            return true
        }
        guard let target = AgentsDestination(rawValue: destination) else { return false }
        currentDestination = target
        mode = .destination(target)
        rebuild()
        return true
    }

    /// The SYSTEM section as the list actually renders it, plus whatever the
    /// open editor holds — automation asserts on what a user would see, not
    /// on the store behind it.
    func qaSystemAgentState() -> [String: Any] {
        var state: [String: Any] = [:]
        state["rows"] = (dataSource?.agentSystemAgentRows() ?? []).map { row in
            [
                "kind": row.kind, "name": row.name, "model": row.model,
                "effort": row.effort, "effort_label": row.effortLabel,
                "trigger": row.trigger, "uses_defaults": row.usesDefaults,
                "instructions": row.instructions,
            ] as [String: Any]
        }
        state["listed"] = contentStack.subviews
            .compactMap { $0 as? AgentListRowView }
            .compactMap { row -> String? in
                guard case .systemAgent(let kind)? = row.rowAction else { return nil }
                return kind
            }
        if let field = systemAgentModelField { state["editor_model"] = field.stringValue }
        if let popUp = systemAgentEffortPopUp {
            state["editor_effort"] = (popUp.selectedItem?.representedObject as? String) ?? ""
        }
        if let view = systemAgentInstructionsView { state["editor_instructions"] = view.string }
        if let inlineError { state["error"] = inlineError }
        if let systemAgentTestResult { state["result"] = systemAgentTestResult }
        state["testing"] = systemAgentTestRunning
        return state
    }

    func qaSystemAgentEdit(model: String?, effort: String?, instructions: String?) -> Bool {
        guard case .systemAgent = mode else { return false }
        if let model { systemAgentModelField?.stringValue = model }
        if let effort { select(popUp: systemAgentEffortPopUp, representedObject: effort) }
        if let instructions { systemAgentInstructionsView?.string = instructions }
        return true
    }

    func qaSystemAgentAction(_ action: String) -> Bool {
        guard case .systemAgent(let kind) = mode else { return false }
        let button = NSButton()
        button.identifier = NSUserInterfaceItemIdentifier(kind)
        switch action {
        case "save": saveSystemAgentTapped(button); return true
        case "reset": resetSystemAgentTapped(button); return true
        case "test": testSystemAgentTapped(button); return true
        default: return false
        }
    }

    func qaThreadUIAction(_ action: String) -> Bool {
        switch action {
        case "lifecycle_tapped": threadLifecycleTapped(); return true
        case "confirm_complete": confirmCompleteThreadTapped(); return true
        case "cancel_complete": cancelCompleteThreadTapped(); return true
        case "attach_probe":
            // Open the real picker, record its level against the panel's, close it.
            pickAttachments()
            let picker = attachPicker
            // Levels only: begin(_:) presents asynchronously, so isVisible
            // is not meaningful on this run-loop turn.
            QAEventRecorder.shared.append("attach_probe", [
                "picker_level": picker?.level.rawValue ?? -1,
                "panel_level": window?.level.rawValue ?? -1,
            ])
            picker?.cancel(nil)
            return picker != nil
        case "scroll_bottom":
            contentStack.layoutSubtreeIfNeeded()
            let bottom = max(0, contentStack.frame.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: bottom))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return true
        default:
            if action.hasPrefix("select_model:"), let index = Int(action.dropFirst("select_model:".count)) {
                return composerField?.selectModel(at: index) ?? false
            }
            return false
        }
    }

    func qaSetComposerText(_ text: String) -> Bool {
        guard let composer = composerField else { return false }
        composer.text = text
        return true
    }

    var qaNavigationState: [String: Any] {
        var state: [String: Any] = [
            "destination": currentDestination.rawValue,
            "thread_filter": threadFilter.label.lowercased(),
            "complete_confirmation_pending": threadCompleteConfirmationID != nil,
        ]
        switch mode {
        case .thread(let id):
            state["mode"] = "thread"
            state["thread_source"] = id.source.rawValue
            state["thread_id"] = id.value
            state["draft"] = composerField?.text ?? threadDrafts[id] ?? ""
        case .search: state["mode"] = "search"
        case .destination: state["mode"] = "destination"
        case .job: state["mode"] = "automation_detail"
        case .automationCreate: state["mode"] = "automation_create"
        case .automationEdit: state["mode"] = "automation_edit"
        case .assistantWorkspace: state["mode"] = "assistant_workspace"
        case .assistantCreate: state["mode"] = "assistant_create"
        case .systemAgent(let kind):
            state["mode"] = "system_agent"
            state["system_agent"] = kind
        }
        return state
    }
#endif

    func openThread(_ sessionId: String) {
        openThread(AgentsThreadID(source: .mcp, value: sessionId))
    }

    func openThread(_ id: AgentsThreadID) {
        if case .thread = mode {} else { pushedOrigin = mode }
        currentDestination = .threads
        if id.source == .assistant { _ = dataSource?.activateThread(id) }
        mode = .thread(id)
        threadInlineError = nil
        rebuild()
        // Selection is navigation, not consumption. Flip seen only after the
        // exact typed detail has actually attached to a visible window.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible == true,
                  case .thread(let visible) = self.mode, visible == id else { return }
            self.dataSource?.markThreadSeen(id)
            self.styleNavigation()
        }
    }

    func beginAssistantThreadStream(conversationID: String) {
        assistantThreadStreams[conversationID] = ""
        if openThreadID == AgentsThreadID(source: .assistant, value: conversationID) {
            refresh()
        }
    }

    func appendAssistantThreadDelta(_ delta: String, conversationID: String) {
        assistantThreadStreams[conversationID, default: ""] += delta
        guard openThreadID == AgentsThreadID(source: .assistant, value: conversationID) else { return }
        assistantThreadStreamingLabel?.stringValue = assistantThreadStreams[conversationID] ?? ""
    }

    func finishAssistantThreadStream(conversationID: String) {
        assistantThreadStreams.removeValue(forKey: conversationID)
        if openThreadID == AgentsThreadID(source: .assistant, value: conversationID) {
            refresh()
        }
    }

    /// Re-render whatever is on screen from fresh data. An in-progress
    /// composer draft (and its focus) survives the rebuild — pushes from
    /// other sessions must never eat what the user is typing.
    func refresh() {
        if case .thread(let id) = mode {
            if let composer = composerField {
                threadDrafts[id] = composer.text
                threadAttachments[id] = composer.attachments
            }
            if dataSource?.agentThreadDetail(for: id) == nil {
                mode = .destination(currentDestination)
            }
        } else if case .job(let id) = mode,
                  dataSource?.agentJobRows().contains(where: { $0.id == id }) != true {
            mode = .destination(currentDestination)
        } else if case .automationEdit(let id) = mode,
                  dataSource?.agentJobRows().contains(where: { $0.id == id }) != true {
            mode = .destination(.automations)
        } else if case .assistantWorkspace(let slug, _) = mode,
                  (try? dataSource?.assistantWorkspace(slug: slug)) == nil {
            mode = .destination(.assistants)
        }
        let readSurface: Bool = {
            switch mode {
            case .destination, .thread, .search: return true
            default: return false
            }
        }()
        let inputs = RefreshInputs(
            mode: mode,
            sessions: dataSource?.agentSessionRows() ?? [],
            jobs: dataSource?.agentJobRows() ?? [],
            assistants: dataSource?.agentAssistantRows() ?? [],
            system: dataSource?.agentSystemAgentRows() ?? [],
            threadFilter: threadFilter,
            searchQuery: searchQuery,
            streamingThreads: assistantThreadStreams.keys.sorted(),
            sourceReviewOnly: openThreadID.flatMap { dataSource?.agentThreadDetail(for: $0)?.sourceReviewOnly })
        if readSurface, inputs == lastRefreshInputs {
#if VOICE_FLOW_QA
            QAEventRecorder.shared.append("agents_refresh", ["rebuilt": false])
#endif
            return
        }
#if VOICE_FLOW_QA
        QAEventRecorder.shared.append("agents_refresh", ["rebuilt": true])
#endif
        let previousComposer = composerField
        let draft = composerField?.text ?? ""
        let hadFocus = (composerField?.hasFocus ?? false) || composerFocusPending
        rebuild()
        lastRefreshInputs = readSurface ? inputs : nil
        if let composer = composerField {
            if composer !== previousComposer {
                if case .thread(let id) = mode {
                    composer.text = threadDrafts[id] ?? draft
                } else if !draft.isEmpty {
                    composer.text = draft
                }
                if hadFocus { composer.focus() }
            } else if composerFocusPending, !composer.hasFocus {
                composer.focus()
            }
            composerFocusPending = false
        } else if case .thread = mode {
            composerFocusPending = hadFocus
        } else {
            composerFocusPending = false
        }
    }

    private func buildJob(_ jobId: String) {
        guard let dataSource,
              let job = dataSource.agentJobRows().first(where: { $0.id == jobId }) else {
            mode = .destination(.automations)
            buildSetup()
            return
        }
        var top = contentStack.topAnchor

        let header = NSView()
        let back = NSButton(title: "‹ Automations", target: self, action: #selector(backTapped))
        back.isBordered = false
        back.font = .systemFont(ofSize: 11.5, weight: .medium)
        back.contentTintColor = Theme.text2
        back.setAccessibilityLabel("Back to automations")
        let title = NSTextField(labelWithString: job.name)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        let edit = NSButton(title: "Edit", target: self,
                            action: #selector(editAutomationTapped(_:)))
        edit.isBordered = false
        edit.font = .systemFont(ofSize: 11, weight: .medium)
        edit.contentTintColor = Theme.accent
        edit.identifier = NSUserInterfaceItemIdentifier(job.id)
        edit.isEnabled = job.state != .running
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor
        for view in [back, title, edit, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            back.topAnchor.constraint(equalTo: header.topAnchor, constant: 1),
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            title.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 5),
            title.trailingAnchor.constraint(lessThanOrEqualTo: edit.leadingAnchor, constant: -8),
            edit.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -2),
            edit.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        place(header, below: &top, gap: 0)

        let status = NSTextField(wrappingLabelWithString: job.preview)
        status.font = .systemFont(ofSize: 12, weight: .semibold)
        status.textColor = job.state == .blocked || job.state == .failed ? Theme.accent : Theme.text
        place(status, below: &top, gap: 13)

        var metaText = job.trigger == .daily
            ? "daily at \(AgentDailyTime.label(minutes: job.dailyTimeMinutes ?? 0)) · \(job.runtime.label)"
            : "\(job.trigger.rawValue) · \(job.runtime.label)"
        if let modelID = job.modelID { metaText += " · \(modelID)" }
        if job.hasPendingTrigger { metaText += " · one follow-up waiting" }
        let meta = NSTextField(wrappingLabelWithString: metaText)
        meta.font = .systemFont(ofSize: 10.5)
        meta.textColor = job.state == .blocked || job.state == .failed ? Theme.accent : Theme.text3
        place(meta, below: &top, gap: 4)

        let budget = NSTextField(labelWithString: String(
            format: "$%.2f / $%.2f today · %.0f min max · %d attempts",
            job.spentTodayUSD, job.dailyBudgetUSD,
            job.maxDurationSeconds / 60, job.maxAttempts))
        budget.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        budget.textColor = Theme.text3
        place(budget, below: &top, gap: 5)

        place(sectionHeader("TASK", count: nil), below: &top, gap: 15)
        let prompt = NSTextField(wrappingLabelWithString: job.prompt)
        prompt.font = .systemFont(ofSize: 12.5)
        prompt.textColor = Theme.text2
        prompt.maximumNumberOfLines = 0
        prompt.isSelectable = true
        place(prompt, below: &top, gap: 7)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.distribution = .fillEqually
        if job.state == .running {
            let stop = NSButton(title: "Stop", target: self,
                                action: #selector(cancelJobTapped(_:)))
            stop.identifier = NSUserInterfaceItemIdentifier(job.id)
            stop.setAccessibilityLabel("Stop current automation run")
            actions.addArrangedSubview(stop)
            let disable = NSButton(title: "Disable", target: self,
                                   action: #selector(toggleJobTapped(_:)))
            disable.identifier = NSUserInterfaceItemIdentifier(job.id)
            disable.tag = 0
            disable.setAccessibilityLabel("Disable automation and stop its current run")
            actions.addArrangedSubview(disable)
        } else if !job.isEnabled {
            let enable = NSButton(title: "Enable", target: self,
                                  action: #selector(toggleJobTapped(_:)))
            enable.identifier = NSUserInterfaceItemIdentifier(job.id)
            enable.tag = 1
            enable.setAccessibilityLabel("Enable automation")
            actions.addArrangedSubview(enable)
        } else {
            let runTitle = job.state == .failed || job.state == .blocked ? "Retry now" : "Run now"
            let run = NSButton(title: runTitle, target: self,
                               action: #selector(runJobTapped(_:)))
            run.identifier = NSUserInterfaceItemIdentifier(job.id)
            run.setAccessibilityLabel(runTitle)
            actions.addArrangedSubview(run)
            let disable = NSButton(title: "Disable", target: self,
                                   action: #selector(toggleJobTapped(_:)))
            disable.identifier = NSUserInterfaceItemIdentifier(job.id)
            disable.tag = 0
            disable.setAccessibilityLabel("Disable automation")
            actions.addArrangedSubview(disable)
        }
        for button in actions.arrangedSubviews.compactMap({ $0 as? NSButton }) {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        place(actions, below: &top, gap: 15)

        place(sectionHeader("RUN HISTORY", count: job.runs.count), below: &top, gap: 18)
        for run in job.runs.prefix(6) {
            let elapsed = run.finishedAt.map { max(0, $0.timeIntervalSince(run.startedAt)) }
            var detail = "Attempt \(run.attempt)"
            if let elapsed { detail += String(format: " · %.0fs", elapsed) }
            if run.costUSD > 0 { detail += String(format: " · $%.3f", run.costUSD) }
            if let error = run.error, !error.isEmpty { detail += " · \(error)" }
            let row = makeRow(
                leading: runStateIcon(run.state),
                name: run.state.rawValue.capitalized,
                unread: run.state == .failed || run.state == .interrupted,
                preview: detail,
                time: DateFormatter.localizedString(
                    from: run.startedAt, dateStyle: .none, timeStyle: .short))
            place(row, below: &top, gap: 6)
        }
        if job.runs.isEmpty { place(emptyLabel("No runs yet"), below: &top, gap: 10) }

        let duplicate = NSButton(title: "Duplicate as disabled", target: self,
                                 action: #selector(duplicateAutomationTapped(_:)))
        duplicate.identifier = NSUserInterfaceItemIdentifier(job.id)
        duplicate.isBordered = false
        duplicate.contentTintColor = Theme.text2
        duplicate.font = .systemFont(ofSize: 11)
        duplicate.isEnabled = job.state != .running
        place(duplicate, below: &top, gap: 18)

        if automationDeleteConfirmationID == job.id {
            place(errorLabel("Delete this automation and its run history? Its conversation is kept in Threads."),
                  below: &top, gap: 10)
            let confirm = NSStackView()
            confirm.orientation = .horizontal
            confirm.spacing = 8
            let delete = NSButton(title: "Delete", target: self,
                                  action: #selector(confirmDeleteAutomationTapped(_:)))
            delete.identifier = NSUserInterfaceItemIdentifier(job.id)
            let cancel = NSButton(title: "Keep", target: self,
                                  action: #selector(cancelDeleteAutomationTapped))
            for button in [delete, cancel] {
                button.bezelStyle = .rounded
                button.controlSize = .small
                confirm.addArrangedSubview(button)
            }
            place(confirm, below: &top, gap: 7)
        } else {
            let delete = NSButton(title: "Delete automation…", target: self,
                                  action: #selector(deleteAutomationTapped(_:)))
            delete.identifier = NSUserInterfaceItemIdentifier(job.id)
            delete.isBordered = false
            delete.contentTintColor = Theme.accent
            delete.font = .systemFont(ofSize: 11)
            delete.isEnabled = job.state != .running
            place(delete, below: &top, gap: 7)
        }

        let bottom = top.constraint(equalTo: contentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    // ── Rendering ───────────────────────────────────────

    private func rebuild() {
        let workspaceRouteChanged = renderedWorkspaceMode != mode
        let formFocus = workspaceRouteChanged ? nil : workspaceFocus()
        let formScroll = !workspaceRouteChanged && !renderedWorkspaceForms.isEmpty
            ? scrollView.contentView.bounds.origin : nil
        captureWorkspaceDrafts()
        inlineFormErrorView = nil
        // Every navigation path funnels through here, so this is the one
        // choke point where an in-progress reply can be captured before its
        // field is torn down — Escape, back, Cmd shortcuts included.
        lastRefreshInputs = nil
        stashComposerDraft()
        if case .thread = mode {} else {
            threadRowCache.removeAll()
            threadRowCacheThread = nil
        }
        // A same-thread update must leave the live text editor attached:
        // replacing it discards selection, undo, and in-progress input methods.
        let keepComposer: Bool = {
            guard case .thread(let id) = mode, id == composerThreadID,
                  let detail = dataSource?.agentThreadDetail(for: id) else { return false }
            return !detail.archived && (detail.canReply || (id.source == .assistant && detail.live))
        }()
        contentStack.subviews.forEach { $0.removeFromSuperview() }
        if !keepComposer {
            clearComposerHost()
            composerField = nil
            composerThreadID = nil
        }
        clearHeaderHost()
        automationSearchField = nil
        automationNameField = nil
        automationInstructionsView = nil
        automationAssistantPopUp = nil
        automationRuntimePopUp = nil
        automationTriggerPopUp = nil
        automationModelCombo = nil
        automationIntervalField = nil
        automationDailyTimeField = nil
        automationBudgetField = nil
        automationDurationField = nil
        automationAttemptsField = nil
        assistantSources = nil
        automationSources = nil
        assistantNameField = nil
        assistantDescriptionField = nil
        assistantVoiceField = nil
        assistantInstructionsView = nil
        assistantMemoryView = nil
        assistantSkillButtons = [:]
        systemAgentModelField = nil
        systemAgentEffortPopUp = nil
        systemAgentInstructionsView = nil
        switch mode {
        case .destination(let destination): buildDestination(destination)
        case .search: buildSearch()
        case .thread(let sid):
#if VOICE_FLOW_QA
            let started = Date()
            buildThread(sid)
            contentStack.layoutSubtreeIfNeeded()
            QAEventRecorder.shared.append("thread_build", [
                "ms": Date().timeIntervalSince(started) * 1000,
                "rows": contentStack.subviews.count,
            ])
#else
            buildThread(sid)
#endif
        case .job(let id): buildJob(id)
        case .automationCreate: buildAutomationForm(jobID: nil)
        case .automationEdit(let id): buildAutomationForm(jobID: id)
        case .assistantWorkspace(let slug, let tab): buildAssistantWorkspace(slug: slug, tab: tab)
        case .assistantCreate: buildAssistantCreate()
        case .systemAgent(let kind): buildSystemAgent(kind: kind)
        }
        restoreWorkspaceDrafts()
        if !renderedWorkspaceForms.isEmpty {
            contentStack.layoutSubtreeIfNeeded()
            restoreWorkspaceFocus(formFocus)
            if let formScroll {
                scrollView.contentView.scroll(to: formScroll)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            if let error = inlineFormErrorView,
               revealInlineFormError || inlineError != renderedInlineFormError {
                error.scrollToVisible(error.bounds.insetBy(dx: 0, dy: -8))
            }
        }
        renderedInlineFormError = inlineFormErrorView == nil ? nil : inlineError
        revealInlineFormError = false
        renderedWorkspaceMode = mode
        styleNavigation()
        onModeChanged?()
        // Content-fit height, the way the mocks are framed: every screen
        // measures its real content and the panel ends just after the last
        // card, clamped by the panel's own floor/ceiling.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.contentStack.layoutSubtreeIfNeeded()
            self.onPreferredHeightChanged?(self.contentStack.frame.height)
        }

        DispatchQueue.main.async { [weak self] in self?.refreshHoverStatesForPointer() }
    }

    /// AppKit does not reliably emit mouseExited when a trackpad scroll moves
    /// a tracking area out from under a stationary pointer. Recompute the one
    /// true hovered row from screen geometry after every clip-view movement.
    private func refreshHoverStatesForPointer() {
        guard let window else {
            contentStack.subviews.compactMap { $0 as? AgentListRowView }
                .forEach { $0.setHovered(false) }
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInScroll = scrollView.convert(pointInWindow, from: nil)
        let pointerInsideScroll = scrollView.bounds.contains(pointInScroll)
        for row in contentStack.subviews.compactMap({ $0 as? AgentListRowView }) {
            let local = row.convert(pointInWindow, from: nil)
            row.setHovered(pointerInsideScroll && row.bounds.contains(local))
        }
    }

    private func buildDestination(_ destination: AgentsDestination) {
        currentDestination = destination
        switch destination {
        case .now: buildNow()
        case .assistants: buildSetup()
        case .automations:
            if workspaceNavigation {
                var top = contentStack.topAnchor
                placeAutomations(below: &top)
                finishContent(top)
            } else { buildSetup() }
        case .threads: buildThreads()
        }
    }

    private func styleNavigation() {
        let threadAttention = AgentsThreadProjection.attentionCount(threadProjectionInputs())
        let attention = nowSnapshot().attentionCount
        for destination in AgentsDestination.navigation {
            guard let button = navigationButtons[destination] else { continue }
            let count: Int
            switch destination {
            case .now: count = attention
            case .threads: count = threadAttention
            case .assistants, .automations: count = 0
            }
            let selected = destination == currentDestination.navigationItem
            button.attributedTitle = NSAttributedString(
                string: destination.label, attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium),
                    .foregroundColor: selected ? Theme.text : Theme.text3,
                ])
            navigationBadges[destination]?.stringValue = " \(count) "
            navigationBadges[destination]?.isHidden = count == 0
            navigationUnderlines[destination]?.isHidden = !selected
        }
        searchButton.contentTintColor = {
            if case .search = mode { return Theme.accent }
            return Theme.text3
        }()
    }

    private func threadProjectionInputs() -> [AgentsThreadProjectionInput] {
        (dataSource?.agentSessionRows() ?? []).map { row in
            AgentsThreadProjectionInput(
                id: AgentsThreadID(
                    source: row.kind == .assistant ? .assistant : .mcp,
                    value: row.id),
                title: row.name, owner: row.owner, preview: row.preview,
                updatedAt: row.updatedAt, unread: row.unread,
                pendingAsk: row.pendingAsk, live: row.live,
                archived: row.archived, running: row.running)
        }
    }

    private func automationProjectionInputs() -> [AgentsAutomationProjectionInput] {
        (dataSource?.agentJobRows() ?? []).compactMap { row in
            guard let state = AgentsAutomationState(rawValue: row.state.rawValue) else { return nil }
            return AgentsAutomationProjectionInput(
                id: row.id, name: row.name, assistantName: row.assistantName,
                updatedAt: row.updatedAt, state: state,
                isEnabled: row.isEnabled)
        }
    }

    private func nowSnapshot() -> AgentsNowSnapshot {
        AgentsNowProjection.snapshot(
            threads: threadProjectionInputs(), automations: automationProjectionInputs())
    }

    private func buildNow() {
        var top = contentStack.topAnchor
        let snapshot = nowSnapshot()
        if snapshot.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "All clear\nNothing needs you, nothing is unread, and no agent is running.")
            empty.font = .systemFont(ofSize: 12.5, weight: .medium)
            empty.textColor = Theme.text2
            empty.alignment = .center
            place(empty, below: &top, gap: 34)
        } else {
            if !snapshot.needsYou.isEmpty {
                place(sectionHeader("NEEDS YOU", count: snapshot.needsYou.count), below: &top, gap: 8)
                for item in snapshot.needsYou { place(makeNowRow(item), below: &top, gap: 6) }
            }
            if !snapshot.running.isEmpty {
                place(sectionHeader("RUNNING NOW", count: snapshot.running.count), below: &top, gap: 14)
                for item in snapshot.running { place(makeNowRow(item), below: &top, gap: 6) }
            }
            if !snapshot.unread.isEmpty {
                place(sectionHeader("UNREAD", count: snapshot.unread.count), below: &top, gap: 14)
                for item in snapshot.unread { place(makeNowRow(item), below: &top, gap: 6) }
            }
        }
        finishContent(top)
    }

    /// Setup = assistants, the three system agents, and automations on one
    /// scrolling screen. Search and filter chips for automations appear only
    /// once there are enough of them to need finding.
    private func buildSetup() {
        var top = contentStack.topAnchor
        let rows = dataSource?.agentAssistantRows() ?? []
        let create = makeRow(
            leading: circled(symbolIcon("plus", description: "new assistant", pointSize: 12)),
            name: "New assistant", unread: false,
            preview: "Create a persistent identity, memory, skills, and workspace", time: "")
        create.rowAction = .newAssistantIdentity
        place(create, below: &top, gap: 2)
        place(sectionHeader("ASSISTANTS", count: rows.count), below: &top, gap: 8)
        for assistant in rows {
            let inventory = "\(assistant.conversationCount) conversations · \(assistant.automationCount) automations · \(assistant.skillCount) skills"
            let state: String
            if assistant.attentionCount > 0 { state = "\(assistant.attentionCount) waiting" }
            else if assistant.running { state = "running" }
            else if assistant.isDefault { state = "default" }
            else { state = "" }
            let view = makeRow(
                leading: circled(WaveformIconView()), name: assistant.name,
                unread: assistant.attentionCount > 0,
                preview: assistant.description.isEmpty
                    ? "Persistent identity" : assistant.description,
                time: state, stats: inventory)
            view.rowAction = .assistantWorkspace(assistant.slug)
            place(view, below: &top, gap: 6)
        }
        if rows.isEmpty { place(emptyLabel("No assistants available"), below: &top, gap: 28) }

        // The three fixed agents the app runs on its own behalf. They have no
        // Assistant, no memory and no thread — they exist so wake routing,
        // read-aloud, and speech work — but their model, reasoning, and brief
        // are yours, so they belong on this list rather than in the source.
        let system = dataSource?.agentSystemAgentRows() ?? []
        if !system.isEmpty {
            place(sectionHeader("SYSTEM", count: system.count), below: &top, gap: 18)
            for agent in system {
                var meta = agent.model
                if agent.supportsEffort, !agent.effortLabel.isEmpty {
                    meta += " · \(agent.effortLabel)"
                }
                let view = makeRow(
                    leading: circled(symbolIcon(
                        systemAgentSymbol(agent.kind), description: agent.name, pointSize: 11)),
                    name: agent.name, unread: false,
                    preview: agent.purpose,
                    time: agent.usesDefaults ? "default" : "tuned",
                    stats: "\(meta) · \(agent.trigger)")
                view.rowAction = .systemAgent(agent.kind)
                place(view, below: &top, gap: 6)
            }
        }
        if !workspaceNavigation || workspaceCombinedSetup { placeAutomations(below: &top) }
        finishContent(top)
    }

    private func systemAgentSymbol(_ kind: String) -> String {
        switch kind {
        case SystemAgentKind.continuity.rawValue: return "arrow.triangle.branch"
        case SystemAgentKind.speechCleanup.rawValue: return "text.badge.checkmark"
        default: return "speaker.wave.2"
        }
    }

    private func buildSystemAgent(kind: String) {
        var top = contentStack.topAnchor
        guard let agent = dataSource?.agentSystemAgentRows().first(where: { $0.kind == kind }) else {
            place(assistantHeader(title: "Agent unavailable"), below: &top, gap: 0)
            finishContent(top)
            return
        }
        place(assistantHeader(title: agent.name), below: &top, gap: 0)

        let purpose = NSTextField(wrappingLabelWithString: agent.purpose)
        purpose.font = .systemFont(ofSize: 11.5)
        purpose.textColor = Theme.text2
        purpose.maximumNumberOfLines = 0
        place(purpose, below: &top, gap: 12)

        let context = NSTextField(wrappingLabelWithString:
            "Runs on \(agent.runsOn).\nTriggered by: \(agent.trigger.lowercased()).")
        context.font = .systemFont(ofSize: 10.5)
        context.textColor = Theme.text3
        context.maximumNumberOfLines = 0
        place(context, below: &top, gap: 8)

        if let inlineError { place(formErrorLabel(inlineError), below: &top, gap: 10) }

        place(formLabel("MODEL"), below: &top, gap: 16)
        let model = formField(placeholder: agent.defaultModel)
        model.stringValue = agent.model
        systemAgentModelField = model
        place(model, below: &top, gap: 5)
        let modelHint = NSTextField(labelWithString: "Default: \(agent.defaultModel) — clear the field to go back to it.")
        modelHint.font = .systemFont(ofSize: 10)
        modelHint.textColor = Theme.text3
        place(modelHint, below: &top, gap: 5)

        if agent.supportsEffort {
            place(formLabel("REASONING"), below: &top, gap: 12)
            let popUp = formPopUp()
            for choice in AgentReasoningEffort.choices {
                popUp.addItem(withTitle: choice.label)
                popUp.lastItem?.representedObject = choice.value
            }
            select(popUp: popUp, representedObject: agent.effort)
            systemAgentEffortPopUp = popUp
            place(popUp, below: &top, gap: 5)
        }

        if agent.editableInstructions {
            place(formLabel("INSTRUCTIONS"), below: &top, gap: 12)
            let editor = makeTextEditor(text: agent.instructions, height: 150)
            systemAgentInstructionsView = editor.textView
            place(editor.view, below: &top, gap: 5)
        } else if !agent.instructions.isEmpty {
            place(formLabel("INSTRUCTIONS"), below: &top, gap: 12)
            let shown = NSTextField(wrappingLabelWithString: agent.instructions)
            shown.font = .systemFont(ofSize: 11)
            shown.textColor = Theme.text2
            shown.maximumNumberOfLines = 0
            place(shown, below: &top, gap: 5)
        }
        if let note = agent.instructionsNote {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = .systemFont(ofSize: 10)
            label.textColor = Theme.text3
            label.maximumNumberOfLines = 0
            place(label, below: &top, gap: 6)
        }
        if let contract = agent.instructionsContract {
            let label = NSTextField(wrappingLabelWithString: contract)
            label.font = .systemFont(ofSize: 10)
            label.textColor = Theme.text3
            label.maximumNumberOfLines = 0
            place(label, below: &top, gap: 6)
        }

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        let save = NSButton(title: "Save", target: self,
                            action: #selector(saveSystemAgentTapped))
        save.identifier = NSUserInterfaceItemIdentifier(agent.kind)
        save.bezelStyle = .rounded
        save.controlSize = .small
        actions.addArrangedSubview(save)
        let test = NSButton(title: systemAgentTestRunning ? "Testing…" : "Test now",
                            target: self, action: #selector(testSystemAgentTapped))
        test.identifier = NSUserInterfaceItemIdentifier(agent.kind)
        test.bezelStyle = .rounded
        test.controlSize = .small
        test.isEnabled = !systemAgentTestRunning
        actions.addArrangedSubview(test)
        if !agent.usesDefaults {
            let reset = NSButton(title: "Reset to default", target: self,
                                 action: #selector(resetSystemAgentTapped))
            reset.identifier = NSUserInterfaceItemIdentifier(agent.kind)
            reset.bezelStyle = .inline
            reset.controlSize = .small
            actions.addArrangedSubview(reset)
        }
        place(actions, below: &top, gap: 16)

        if let result = systemAgentTestResult {
            let label = NSTextField(wrappingLabelWithString: result)
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = Theme.text2
            label.maximumNumberOfLines = 0
            place(label, below: &top, gap: 10)
        }
        finishContent(top)
    }

    @objc private func saveSystemAgentTapped(_ sender: NSButton) {
        guard let kind = sender.identifier?.rawValue else { return }
        let effort = systemAgentEffortPopUp
            .map { ($0.selectedItem?.representedObject as? String) ?? AgentReasoningEffort.unset }
        do {
            try dataSource?.updateAgentSystemAgent(
                kind: kind,
                model: systemAgentModelField?.stringValue ?? "",
                effort: effort,
                instructions: systemAgentInstructionsView?.string)
            inlineError = nil
            systemAgentTestResult = "Saved. The next run of this agent uses it."
            clearWorkspaceDraft("system:\(kind)")
        } catch {
            inlineError = error.localizedDescription
            revealInlineFormError = true
        }
        rebuild()
    }

    @objc private func resetSystemAgentTapped(_ sender: NSButton) {
        guard let kind = sender.identifier?.rawValue else { return }
        do {
            try dataSource?.resetAgentSystemAgent(kind: kind)
            inlineError = nil
            systemAgentTestResult = "Back to the shipped defaults."
            clearWorkspaceDraft("system:\(kind)")
        } catch {
            inlineError = error.localizedDescription
            revealInlineFormError = true
        }
        rebuild()
    }

    @objc private func testSystemAgentTapped(_ sender: NSButton) {
        guard let kind = sender.identifier?.rawValue, !systemAgentTestRunning else { return }
        systemAgentTestRunning = true
        systemAgentTestResult = "Running the real path with the saved config…"
        rebuild()
        dataSource?.testAgentSystemAgent(kind: kind) { [weak self] outcome in
            guard let self else { return }
            self.systemAgentTestRunning = false
            self.systemAgentTestResult = outcome
            if case .systemAgent = self.mode { self.rebuild() }
        }
    }

    private func buildAssistantCreate() {
        var top = contentStack.topAnchor
        place(assistantHeader(title: "New assistant"), below: &top, gap: 0)
        place(formLabel("NAME"), below: &top, gap: 14)
        let name = formField(placeholder: "Research Helper")
        assistantNameField = name
        place(name, below: &top, gap: 5)

        place(formLabel("DESCRIPTION"), below: &top, gap: 12)
        let description = formField(placeholder: "What this Assistant is for")
        assistantDescriptionField = description
        place(description, below: &top, gap: 5)

        place(formLabel("INSTRUCTIONS"), below: &top, gap: 12)
        let editor = makeTextEditor(text: "", height: 126)
        assistantInstructionsView = editor.textView
        place(editor.view, below: &top, gap: 5)

        if let inlineError { place(formErrorLabel(inlineError), below: &top, gap: 10) }
        let create = NSButton(title: "Create assistant", target: self,
                              action: #selector(createAssistantTapped))
        create.bezelStyle = .rounded
        create.controlSize = .small
        create.setAccessibilityLabel("Create assistant")
        place(create, below: &top, gap: 16)
        finishContent(top)
    }

    private func buildAssistantWorkspace(slug: String, tab: AssistantWorkspaceTab) {
        guard let dataSource else { return }
        let snapshot: AssistantWorkspaceSnapshot
        do { snapshot = try dataSource.assistantWorkspace(slug: slug) }
        catch {
            var top = contentStack.topAnchor
            place(assistantHeader(title: "Assistant unavailable"), below: &top, gap: 0)
            place(errorLabel(error.localizedDescription), below: &top, gap: 18)
            finishContent(top)
            return
        }

        var top = contentStack.topAnchor
        place(assistantHeader(title: snapshot.document.definition.name), below: &top, gap: 0)
        place(assistantTabs(selected: tab), below: &top, gap: 8)
        if let inlineError { place(formErrorLabel(inlineError), below: &top, gap: 8) }

        switch tab {
        case .overview:
            buildAssistantOverview(snapshot, top: &top)
        case .conversations:
            buildAssistantConversations(snapshot, top: &top)
        case .memory:
            buildAssistantMemory(snapshot, top: &top)
        case .settings:
            buildAssistantSettings(snapshot, top: &top)
        }
        finishContent(top)
    }

    private func buildAssistantOverview(_ snapshot: AssistantWorkspaceSnapshot,
                                        top: inout NSLayoutYAxisAnchor) {
        let assistant = snapshot.document.definition
        let runningConversation = snapshot.conversations.first { $0.turnState == .running }
        let attentionJobs = snapshot.jobs.filter { $0.state == .blocked || $0.state == .failed }
        place(sectionHeader("CURRENT WORK", count: (runningConversation == nil ? 0 : 1) + attentionJobs.count),
              below: &top, gap: 14)
        if let runningConversation {
            let row = makeRow(
                leading: WaveformIconView(), name: runningConversation.title,
                unread: false, preview: "Working now", time: "")
            row.rowAction = .assistant(runningConversation.id)
            place(row, below: &top, gap: 6)
        }
        for job in attentionJobs.prefix(2) {
            let title = job.prompt.components(separatedBy: .newlines).first ?? "Automation"
            let row = makeRow(
                leading: jobStateIcon(job.state), name: title,
                unread: true, preview: job.state.rawValue, time: "")
            row.rowAction = .job(job.id)
            place(row, below: &top, gap: 6)
        }
        if runningConversation == nil && attentionJobs.isEmpty {
            place(emptyLabel("Nothing active"), below: &top, gap: 12)
        }

        let recent = snapshot.conversations.filter { !$0.messages.isEmpty }.prefix(3)
        place(sectionHeader("CONTINUE", count: snapshot.conversations.filter { !$0.messages.isEmpty }.count),
              below: &top, gap: 18)
        for conversation in recent {
            let row = makeAssistantConversationRow(conversation)
            place(row, below: &top, gap: 6)
        }
        if recent.isEmpty { place(emptyLabel("No conversations yet"), below: &top, gap: 10) }

        let summary = NSTextField(wrappingLabelWithString:
            "\(snapshot.jobs.count) automations  ·  \(assistant.selectedSkills.count) skills  ·  \(snapshot.coreMemory.content.count) / \(AgentMemoryStore.coreLimit) core memory")
        summary.font = .systemFont(ofSize: 11.5)
        summary.textColor = Theme.text3
        place(summary, below: &top, gap: 18)
    }

    private func buildAssistantConversations(_ snapshot: AssistantWorkspaceSnapshot,
                                             top: inout NSLayoutYAxisAnchor) {
        let create = makeRow(
            leading: symbolIcon("plus", description: "new conversation"),
            name: "New conversation", unread: false,
            preview: "Start a clean thread with \(snapshot.document.definition.name)", time: "")
        create.rowAction = .newAssistantConversation(snapshot.document.definition.slug)
        place(create, below: &top, gap: 12)
        place(sectionHeader("CONVERSATIONS", count: snapshot.conversations.count),
              below: &top, gap: 12)
        for conversation in snapshot.conversations {
            place(makeAssistantConversationRow(conversation), below: &top, gap: 0)
        }
        if snapshot.conversations.isEmpty {
            place(emptyLabel("No conversations yet"), below: &top, gap: 20)
        }
    }

    private func buildAssistantMemory(_ snapshot: AssistantWorkspaceSnapshot,
                                      top: inout NSLayoutYAxisAnchor) {
        assistantSkillsRevision = snapshot.document.revision
        let selector = NSStackView()
        selector.orientation = .horizontal
        selector.spacing = 8
        for kind in ["core", "ledger"] {
            let button = NSButton(title: kind.capitalized, target: self,
                                  action: #selector(assistantMemoryKindTapped(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(kind)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.state = assistantMemoryKind == kind ? .on : .off
            selector.addArrangedSubview(button)
        }
        place(selector, below: &top, gap: 14)

        let document = assistantMemoryKind == "ledger" ? snapshot.ledger : snapshot.coreMemory
        assistantMemoryRevision = document.revision
        let limit = assistantMemoryKind == "ledger"
            ? AgentMemoryStore.ledgerLimit : AgentMemoryStore.coreLimit
        let counter = NSTextField(labelWithString: "\(document.content.count) / \(limit)")
        counter.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        counter.textColor = document.clipped ? Theme.accent : Theme.text3
        place(counter, below: &top, gap: 8)

        let editor = makeTextEditor(text: document.content, height: 180)
        editor.textView.isEditable = !document.clipped
        assistantMemoryView = editor.textView
        place(editor.view, below: &top, gap: 6)
        if document.clipped {
            place(errorLabel("Memory is over the visible cap. Open the file in an editor to reduce it."),
                  below: &top, gap: 8)
        } else {
            let save = NSButton(title: "Save memory", target: self,
                                action: #selector(saveAssistantMemoryTapped))
            save.bezelStyle = .rounded
            save.controlSize = .small
            place(save, below: &top, gap: 10)
            let reload = NSButton(title: "Reload saved memory", target: self,
                                  action: #selector(reloadAssistantMemoryTapped))
            reload.bezelStyle = .inline
            reload.controlSize = .small
            reload.toolTip = "Discard unsaved changes to this memory document and load its latest saved version."
            place(reload, below: &top, gap: 4)
        }

        place(sectionHeader("SKILLS", count: snapshot.skills.count), below: &top, gap: 20)
        for skill in snapshot.skills {
            let button = NSButton(checkboxWithTitle: skill.name, target: nil, action: nil)
            button.state = skill.selected ? .on : .off
            button.isEnabled = skill.error == nil
            button.toolTip = skill.error ?? skill.description
            assistantSkillButtons[skill.name] = button
            place(button, below: &top, gap: 5)
            if let error = skill.error { place(errorLabel(error), below: &top, gap: 2) }
        }
        if !snapshot.skills.isEmpty {
            let saveSkills = NSButton(title: "Save skills", target: self,
                                      action: #selector(saveAssistantSkillsTapped))
            saveSkills.bezelStyle = .rounded
            saveSkills.controlSize = .small
            place(saveSkills, below: &top, gap: 10)
            let reload = NSButton(title: "Reload saved skills", target: self,
                                  action: #selector(reloadAssistantSkillsTapped))
            reload.bezelStyle = .inline
            reload.controlSize = .small
            reload.toolTip = "Discard unsaved skill selections and load the latest saved selection."
            place(reload, below: &top, gap: 4)
        }
    }

    private func buildAssistantSettings(_ snapshot: AssistantWorkspaceSnapshot,
                                        top: inout NSLayoutYAxisAnchor) {
        assistantSettingsRevision = snapshot.document.revision
        let definition = snapshot.document.definition
        place(formLabel("NAME"), below: &top, gap: 14)
        let name = formField(placeholder: "Assistant name")
        name.stringValue = definition.name
        assistantNameField = name
        place(name, below: &top, gap: 5)

        place(formLabel("DESCRIPTION"), below: &top, gap: 12)
        let description = formField(placeholder: "What this Assistant is for")
        description.stringValue = definition.description
        assistantDescriptionField = description
        place(description, below: &top, gap: 5)

        place(formLabel("REPLY VOICE"), below: &top, gap: 12)
        let voice = formField(placeholder: "Use global voice")
        voice.stringValue = definition.voice ?? ""
        assistantVoiceField = voice
        place(voice, below: &top, gap: 5)

        place(formLabel("INSTRUCTIONS"), below: &top, gap: 12)
        let editor = makeTextEditor(text: definition.instructions, height: 170)
        assistantInstructionsView = editor.textView
        place(editor.view, below: &top, gap: 5)

        place(formLabel("DATA"), below: &top, gap: 18)
        let sources = SourceSelectionView(options: dataSource?.agentDataSourceOptions() ?? [],
            selectedIDs: definition.selectedSourceIDs, mode: definition.sourceAccessMode)
        assistantSources = sources
        place(sources, below: &top, gap: 8)
        let manage = NSButton(title: "Manage sources", target: self, action: #selector(manageSourcesTapped))
        manage.bezelStyle = .rounded
        place(manage, below: &top, gap: 8)

        let save = NSButton(title: "Save settings", target: self,
                            action: #selector(saveAssistantSettingsTapped))
        save.identifier = NSUserInterfaceItemIdentifier(snapshot.document.revision)
        save.bezelStyle = .rounded
        save.controlSize = .small
        place(save, below: &top, gap: 12)
        let reload = NSButton(title: "Reload saved settings", target: self,
                              action: #selector(reloadAssistantSettingsTapped))
        reload.bezelStyle = .inline
        reload.controlSize = .small
        reload.toolTip = "Discard unsaved settings changes and load the latest saved version."
        place(reload, below: &top, gap: 4)

        let duplicate = NSButton(title: "Duplicate as template", target: self,
                                 action: #selector(duplicateAssistantTapped))
        duplicate.bezelStyle = .inline
        duplicate.controlSize = .small
        place(duplicate, below: &top, gap: 10)

        place(formLabel("DESTRUCTIVE"), below: &top, gap: 22)
        if assistantDeleteConfirmationSlug == definition.slug {
            let warning = NSTextField(wrappingLabelWithString:
                "Move this Assistant's folder to Trash, disable \(snapshot.jobs.count) automations, and keep \(snapshot.conversations.count) conversations read-only in Threads.")
            warning.font = .systemFont(ofSize: 11)
            warning.textColor = Theme.accent
            warning.maximumNumberOfLines = 0
            place(warning, below: &top, gap: 6)
            let actions = NSStackView()
            actions.orientation = .horizontal
            actions.spacing = 8
            let confirm = NSButton(title: "Move to Trash", target: self,
                                   action: #selector(confirmDeleteAssistantTapped))
            confirm.bezelStyle = .rounded
            let cancel = NSButton(title: "Cancel", target: self,
                                  action: #selector(cancelDeleteAssistantTapped))
            cancel.bezelStyle = .rounded
            actions.addArrangedSubview(confirm)
            actions.addArrangedSubview(cancel)
            place(actions, below: &top, gap: 10)
        } else {
            let remove = NSButton(title: "Delete assistant…", target: self,
                                  action: #selector(deleteAssistantTapped))
            remove.bezelStyle = .inline
            remove.contentTintColor = Theme.accent
            place(remove, below: &top, gap: 6)
        }
    }

    private func makeAssistantConversationRow(_ conversation: AssistantConversation) -> AgentListRowView {
        var state = ""
        if conversation.turnState == .running { state = "working" }
        else if conversation.turnState == .interrupted { state = "interrupted" }
        else if conversation.completedAt != nil { state = "done" }
        else if conversation.hasUnseenAssistantReply { state = "reply" }
        let row = makeRow(
            leading: WaveformIconView(), name: conversation.title,
            unread: conversation.hasUnseenAssistantReply,
            preview: conversation.preview, time: state)
        row.rowAction = .assistant(conversation.id)
        return row
    }

    private func assistantHeader(title: String) -> NSView {
        let header = NSView()
        let back = NSButton(title: "‹ Assistants", target: self, action: #selector(backTapped))
        back.isBordered = false
        back.font = .systemFont(ofSize: 11.5, weight: .medium)
        back.contentTintColor = Theme.text2
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor
        for view in [back, label, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            back.topAnchor.constraint(equalTo: header.topAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 5),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    private func assistantTabs(selected: AssistantWorkspaceTab) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.distribution = .fillEqually
        for tab in AssistantWorkspaceTab.allCases {
            let button = NSButton(title: tab.rawValue, target: self,
                                  action: #selector(assistantTabTapped(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(tab.rawValue)
            button.isBordered = false
            button.font = .systemFont(ofSize: 9.5, weight: tab == selected ? .semibold : .regular)
            button.contentTintColor = tab == selected ? Theme.accent : Theme.text3
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func formLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = Theme.text3
        return label
    }

    /// Swap in the padded cell, preserving the field's configuration.
    private func applyPaddedCell(_ field: NSTextField, fontSize: CGFloat) {
        let cell = PaddedTextFieldCell(textCell: field.stringValue)
        cell.placeholderString = field.placeholderString
        cell.isEditable = true
        cell.isSelectable = true
        cell.isScrollable = true
        cell.usesSingleLineMode = true
        cell.wraps = false
        cell.font = .systemFont(ofSize: fontSize)
        field.cell = cell
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = Theme.text
        field.isBezeled = false
        field.focusRingType = .none
        // The rounded layer paints the background; the cell must not, or it
        // covers the corner radius with an opaque square.
        field.drawsBackground = false
    }

    private func formField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        applyPaddedCell(field, fontSize: 12)
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10).cgColor
        field.layer?.cornerRadius = 7
        field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        return field
    }

    private func makeTextEditor(text: String, height: CGFloat) -> (view: NSScrollView, textView: NSTextView) {
        let editor = NSTextView()
        editor.string = text
        editor.font = .systemFont(ofSize: 12)
        editor.textColor = Theme.text
        editor.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.textContainerInset = NSSize(width: 8, height: 7)
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 7
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return (scroll, editor)
    }

    private func errorLabel(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = Theme.accent
        label.maximumNumberOfLines = 0
        return label
    }

    private func rebuildPreservingAssistantDraft() {
        revealInlineFormError = inlineError != nil
        rebuild()
    }

    private func formErrorLabel(_ message: String) -> NSTextField {
        let label = errorLabel(message)
        inlineFormErrorView = label
        return label
    }

    private func currentAutomationFormValues() -> AutomationFormValues {
        AutomationFormValues(
            name: automationNameField?.stringValue ?? "",
            instructions: automationInstructionsView?.string ?? "",
            assistantSlug: automationAssistantPopUp?.selectedItem?.representedObject as? String,
            runtime: automationRuntimePopUp?.selectedItem?.representedObject as? String,
            trigger: automationTriggerPopUp?.selectedItem?.representedObject as? String,
            model: automationModelCombo?.stringValue ?? "",
            interval: automationIntervalField?.stringValue ?? "",
            dailyTime: automationDailyTimeField?.stringValue ?? "",
            budget: automationBudgetField?.stringValue ?? "",
            duration: automationDurationField?.stringValue ?? "",
            attempts: automationAttemptsField?.stringValue ?? "",
            selectedSourceIDs: automationSources?.selectedIDs ?? [],
            sourceAccessMode: automationSources?.selectedMode ?? .standard)
    }

    private func automationDraft(from values: AutomationFormValues) -> AgentAutomationDraft? {
        let name = values.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = values.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            inlineError = "Name cannot be empty."
            return nil
        }
        guard !prompt.isEmpty else {
            inlineError = "Instructions cannot be empty."
            return nil
        }
        guard let assistantSlug = values.assistantSlug, !assistantSlug.isEmpty else {
            inlineError = "Choose an Assistant."
            return nil
        }
        guard let runtimeRaw = values.runtime,
              let runtime = AgentRuntimeKind(rawValue: runtimeRaw),
              let triggerRaw = values.trigger,
              let trigger = AgentJobTriggerKind(rawValue: triggerRaw) else {
            inlineError = "Runtime or trigger is unavailable."
            return nil
        }
        let intervalMinutes = Double(values.interval) ?? 0
        if trigger == .interval && intervalMinutes < 1 {
            inlineError = "Interval must be at least one minute."
            return nil
        }
        var dailyTimeMinutes: Int?
        if trigger == .daily {
            guard let parsed = AgentDailyTime.minutes(from: values.dailyTime) else {
                inlineError = "Daily time must look like 08:00."
                return nil
            }
            dailyTimeMinutes = parsed
        }
        let budget = Double(values.budget) ?? -1
        let durationMinutes = Double(values.duration) ?? 0
        let attempts = Int(values.attempts) ?? 0
        guard budget >= 0 else {
            inlineError = "Daily budget cannot be negative."
            return nil
        }
        guard durationMinutes >= 0.5 else {
            inlineError = "Maximum runtime must be at least 0.5 minutes."
            return nil
        }
        guard attempts >= 1 else {
            inlineError = "Attempts must be at least one."
            return nil
        }
        let model = automationModelCombo?.selectedModelID
        if (runtime == .opencode || values.sourceAccessMode == .reviewCopies) && model == nil {
            inlineError = "Choose a catalog model or enter an exact provider/model ID."
            return nil
        }
        let enabled: Bool = {
            if case .automationEdit(let id) = mode {
                return dataSource?.agentJobRows().first(where: { $0.id == id })?.isEnabled ?? true
            }
            return true
        }()
        return AgentAutomationDraft(
            name: name, assistantSlug: assistantSlug,
            runtime: runtime, modelID: (runtime == .opencode || values.sourceAccessMode == .reviewCopies) ? model : nil,
            trigger: trigger, prompt: prompt,
            intervalSeconds: trigger == .interval ? intervalMinutes * 60 : nil,
            dailyTimeMinutes: dailyTimeMinutes,
            dailyBudgetUSD: budget,
            maxDurationSeconds: durationMinutes * 60,
            maxAttempts: attempts, enabled: enabled, selectedSourceIDs: values.selectedSourceIDs,
            sourceAccessMode: values.sourceAccessMode)
    }

    private func rebuildPreservingAutomationForm(_ values: AutomationFormValues) {
        revealInlineFormError = inlineError != nil
        rebuild()
        restoreAutomationForm(values)
    }

    private func restoreAutomationForm(_ values: AutomationFormValues) {
        automationSources?.select(ids: values.selectedSourceIDs, mode: values.sourceAccessMode)
        automationNameField?.stringValue = values.name
        automationInstructionsView?.string = values.instructions
        select(popUp: automationAssistantPopUp, representedObject: values.assistantSlug)
        select(popUp: automationRuntimePopUp, representedObject: values.runtime)
        select(popUp: automationTriggerPopUp, representedObject: values.trigger)
        automationModelCombo?.stringValue = values.model
        automationIntervalField?.stringValue = values.interval
        automationDailyTimeField?.stringValue = values.dailyTime
        automationBudgetField?.stringValue = values.budget
        automationDurationField?.stringValue = values.duration
        automationAttemptsField?.stringValue = values.attempts
        updateAutomationFormAvailability()
    }

    private func select(popUp: NSPopUpButton?, representedObject: String?) {
        guard let representedObject,
              let index = popUp?.itemArray.firstIndex(where: {
                  ($0.representedObject as? String) == representedObject
              }) else { return }
        popUp?.selectItem(at: index)
    }

    private static let automationToolsThreshold = 6

    private func placeAutomations(below top: inout NSLayoutYAxisAnchor) {
        let allJobs = dataSource?.agentJobRows() ?? []
        place(sectionHeader("AUTOMATIONS", count: allJobs.count), below: &top, gap: 18)
        let create = makeRow(
            leading: circled(symbolIcon("plus", description: "new automation", pointSize: 12)),
            name: "New automation", unread: false,
            preview: "A prompt an assistant runs on a schedule or on demand", time: "")
        create.rowAction = .newJob
        place(create, below: &top, gap: 6)

        let showTools = allJobs.count >= Self.automationToolsThreshold
        if showTools {
            let search = formField(placeholder: "Search automations")
            search.stringValue = automationSearchQuery
            search.delegate = self
            search.setAccessibilityLabel("Search automations")
            automationSearchField = search
            place(search, below: &top, gap: 10)
            let filter = makeFilterStrip(
                labels: AutomationFilter.allCases.map(\.label),
                selected: automationFilter.rawValue,
                action: #selector(automationFilterChanged(_:)))
            filter.setAccessibilityLabel("Filter automations")
            place(filter, below: &top, gap: 8)
        } else {
            automationSearchQuery = ""
            automationFilter = .all
        }

        let jobs = allJobs.filter { automationMatches($0) }
        let projections = jobs.compactMap { row -> AgentsAutomationProjectionInput? in
            guard let state = AgentsAutomationState(rawValue: row.state.rawValue) else { return nil }
            return AgentsAutomationProjectionInput(
                id: row.id, name: row.name, assistantName: row.assistantName,
                updatedAt: row.updatedAt, state: state, isEnabled: row.isEnabled)
        }
        let grouped = AgentsAutomationProjection.grouped(projections)
        let jobsByID = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        for group in AgentsAutomationGroup.allCases {
            let members = (grouped[group] ?? []).compactMap { jobsByID[$0.id] }
            guard !members.isEmpty else { continue }
            place(sectionHeader(group.label.uppercased(), count: members.count), below: &top, gap: 12)
            for job in members {
                let needsReview = job.isEnabled
                    && (job.state == .blocked || job.state == .failed)
                let view = makeRow(
                    leading: job.isEnabled
                        ? jobStateIcon(job.state)
                        : circled(symbolIcon("pause.circle", description: "automation disabled",
                                             pointSize: 12)),
                    name: job.name,
                    unread: job.state == .blocked || job.state == .failed,
                    preview: "\(job.assistantName) · \(job.preview)", time: job.time,
                    action: needsReview ? "Review" : nil,
                    progress: jobProgress(job))
                view.rowAction = .job(job.id)
                place(view, below: &top, gap: 6)
            }
        }
        if jobs.isEmpty, !allJobs.isEmpty {
            place(emptyLabel("No automations match this view"), below: &top, gap: 16)
        }
    }

    private func automationMatches(_ job: AgentJobRow) -> Bool {
        let group: AgentsAutomationGroup = {
            if !job.isEnabled { return .disabled }
            switch job.state {
            case .blocked, .failed: return .needsAttention
            case .running, .queued: return .activeUpcoming
            case .completed: return .ready
            case .cancelled, .disabled: return .disabled
            }
        }()
        let filterMatches: Bool
        switch automationFilter {
        case .all: filterMatches = true
        case .attention: filterMatches = group == .needsAttention
        case .active: filterMatches = group == .activeUpcoming
        case .ready: filterMatches = group == .ready
        case .disabled: filterMatches = group == .disabled
        }
        guard filterMatches else { return false }
        let tokens = automationSearchQuery
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased().split(whereSeparator: { $0.isWhitespace })
        guard !tokens.isEmpty else { return true }
        let haystack = [
            job.name, job.assistantName, job.prompt, job.preview,
            job.runtime.label, job.trigger.rawValue, job.modelID ?? "",
        ].joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }

    private func buildAutomationForm(jobID: String?) {
        guard let dataSource else { return }
        let existing = jobID.flatMap { id in
            dataSource.agentJobRows().first { $0.id == id }
        }
        if jobID != nil, existing == nil {
            mode = .destination(.automations)
            buildSetup()
            return
        }
        let defaults = dataSource.agentAutomationDefaults()
        let assistants = dataSource.agentAssistantRows()
        let runtime = existing?.runtime ?? defaults.runtime
        let selectedAssistant = existing?.assistantSlug
            ?? assistants.first(where: \.isDefault)?.slug
            ?? assistants.first?.slug
            ?? ""

        var top = contentStack.topAnchor
        place(automationFormHeader(title: existing == nil ? "New automation" : "Edit automation"),
              below: &top, gap: 0)

        place(formLabel("NAME"), below: &top, gap: 13)
        let name = formField(placeholder: "Morning operating brief")
        name.stringValue = existing?.name ?? ""
        automationNameField = name
        place(name, below: &top, gap: 5)

        let assistant = formPopUp()
        for row in assistants {
            assistant.addItem(withTitle: row.name)
            assistant.lastItem?.representedObject = row.slug
        }
        if let index = assistant.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == selectedAssistant
        }) { assistant.selectItem(at: index) }
        assistant.setAccessibilityLabel("Automation Assistant")
        automationAssistantPopUp = assistant

        let runtimePopUp = formPopUp()
        for kind in AgentRuntimeKind.allCases {
            runtimePopUp.addItem(withTitle: kind.label)
            runtimePopUp.lastItem?.representedObject = kind.rawValue
        }
        if let index = runtimePopUp.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == runtime.rawValue
        }) { runtimePopUp.selectItem(at: index) }
        runtimePopUp.target = self
        runtimePopUp.action = #selector(automationFormControlChanged)
        runtimePopUp.setAccessibilityLabel("Automation runtime")
        automationRuntimePopUp = runtimePopUp
        place(automationFormRow([
            ("ASSISTANT", assistant), ("RUNTIME", runtimePopUp),
        ]), below: &top, gap: 12)

        place(formLabel("INSTRUCTIONS"), below: &top, gap: 12)
        let instructions = makeTextEditor(text: existing?.prompt ?? "", height: 96)
        automationInstructionsView = instructions.textView
        place(instructions.view, below: &top, gap: 5)

        let trigger = formPopUp()
        for kind in AgentJobTriggerKind.allCases {
            trigger.addItem(withTitle: automationTriggerLabel(kind))
            trigger.lastItem?.representedObject = kind.rawValue
        }
        let selectedTrigger = existing?.trigger ?? .manual
        if let index = trigger.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == selectedTrigger.rawValue
        }) { trigger.selectItem(at: index) }
        trigger.target = self
        trigger.action = #selector(automationFormControlChanged)
        trigger.setAccessibilityLabel("Automation trigger")
        automationTriggerPopUp = trigger

        let interval = formField(placeholder: "60")
        interval.stringValue = String(format: "%g", (existing?.intervalSeconds ?? 3_600) / 60)
        interval.setAccessibilityLabel("Automation interval in minutes")
        automationIntervalField = interval
        let dailyTime = formField(placeholder: "08:00")
        dailyTime.stringValue = AgentDailyTime.label(minutes: existing?.dailyTimeMinutes ?? 8 * 60)
        dailyTime.setAccessibilityLabel("Automation daily run time (HH:MM)")
        automationDailyTimeField = dailyTime
        place(automationFormRow([
            ("TRIGGER", trigger), ("EVERY (MIN)", interval), ("AT (HH:MM)", dailyTime),
        ]), below: &top, gap: 12)

        place(formLabel("DATA"), below: &top, gap: 16)
        let assistantDefinition = (try? dataSource.assistantWorkspace(slug: selectedAssistant))?.document.definition
        let sources = SourceSelectionView(options: dataSource.agentDataSourceOptions(),
            selectedIDs: existing?.selectedSourceIDs ?? assistantDefinition?.selectedSourceIDs ?? [],
            mode: existing?.sourceAccessMode ?? assistantDefinition?.sourceAccessMode ?? .standard)
        automationSources = sources
        sources.onChange = { [weak self] in self?.updateAutomationFormAvailability() }
        place(sources, below: &top, gap: 8)
        if existing == nil {
            place(errorLabel("Selections start from this Assistant and are saved independently for this automation."), below: &top, gap: 5)
        }
        let manage = NSButton(title: "Manage sources", target: self, action: #selector(manageSourcesTapped))
        manage.bezelStyle = .rounded
        place(manage, below: &top, gap: 6)

        place(formLabel("OPENROUTER MODEL"), below: &top, gap: 12)
        let model = OpenRouterModelComboBox()
        let selectedModelID = existing?.modelID ?? defaults.modelID ?? ""
        model.configure(
            models: dataSource.agentAutomationModels(),
            selectedID: selectedModelID)
        model.setAccessibilityLabel("OpenRouter model")
        dataSource.refreshAgentAutomationModels { [weak model] models in
            // Never yank the catalog out from under an open dropdown or a
            // half-typed query — the next editor opens with the fresh list.
            guard let model, !models.isEmpty, model.currentEditor() == nil else { return }
            model.configure(
                models: models,
                selectedID: model.committedModelID ?? selectedModelID)
        }
        model.heightAnchor.constraint(equalToConstant: 30).isActive = true
        automationModelCombo = model
        place(model, below: &top, gap: 5)

        let budget = formField(placeholder: "1.00")
        budget.stringValue = String(format: "%.2f", existing?.dailyBudgetUSD ?? 1)
        budget.setAccessibilityLabel("Daily budget in dollars")
        automationBudgetField = budget
        let duration = formField(placeholder: "15")
        duration.stringValue = String(format: "%g", (existing?.maxDurationSeconds ?? 900) / 60)
        duration.setAccessibilityLabel("Maximum runtime in minutes")
        automationDurationField = duration
        let attempts = formField(placeholder: "3")
        attempts.stringValue = String(existing?.maxAttempts ?? 3)
        attempts.setAccessibilityLabel("Maximum attempts")
        automationAttemptsField = attempts
        place(automationFormRow([
            ("BUDGET / DAY", budget), ("MAX MIN", duration), ("ATTEMPTS", attempts),
        ]), below: &top, gap: 12)

        if let inlineError { place(formErrorLabel(inlineError), below: &top, gap: 10) }
        let save = NSButton(
            title: existing == nil ? "Create automation" : "Save changes",
            target: self, action: #selector(saveAutomationTapped(_:)))
        save.identifier = jobID.map { NSUserInterfaceItemIdentifier($0) }
        save.bezelStyle = .rounded
        save.controlSize = .small
        save.setAccessibilityLabel(save.title)
        place(save, below: &top, gap: 16)
        finishContent(top)
        updateAutomationFormAvailability()
    }

    private func automationFormHeader(title: String) -> NSView {
        let header = NSView()
        let back = NSButton(title: "‹ Automations", target: self, action: #selector(backTapped))
        back.isBordered = false
        back.font = .systemFont(ofSize: 11.5, weight: .medium)
        back.contentTintColor = Theme.text2
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = Theme.text
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor
        for view in [back, label, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            back.topAnchor.constraint(equalTo: header.topAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            label.topAnchor.constraint(equalTo: back.bottomAnchor, constant: 5),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            line.heightAnchor.constraint(equalToConstant: 1),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    private func automationFormRow(_ fields: [(String, NSView)]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 8
        for (label, control) in fields {
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 5
            column.addArrangedSubview(formLabel(label))
            control.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(control)
            control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            row.addArrangedSubview(column)
        }
        return row
    }

    private func formPopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.font = .systemFont(ofSize: 11.5)
        popUp.isBordered = false
        popUp.contentTintColor = Theme.text
        popUp.wantsLayer = true
        popUp.layer?.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10).cgColor
        popUp.layer?.cornerRadius = 7
        popUp.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return popUp
    }

    private func automationTriggerLabel(_ trigger: AgentJobTriggerKind) -> String {
        switch trigger {
        case .manual: return "Manual"
        case .interval: return "Interval"
        case .daily: return "Daily at time"
        case .inbox: return "Inbox message"
        case .capture: return "Capture completed"
        case .watcher: return "Watcher action"
        }
    }

    private func updateAutomationFormAvailability() {
        let runtime = automationRuntimePopUp?.selectedItem?.representedObject as? String
        automationModelCombo?.isEnabled = runtime == AgentRuntimeKind.opencode.rawValue || automationSources?.selectedMode == .reviewCopies
        let trigger = automationTriggerPopUp?.selectedItem?.representedObject as? String
        automationIntervalField?.isEnabled = trigger == AgentJobTriggerKind.interval.rawValue
        automationDailyTimeField?.isEnabled = trigger == AgentJobTriggerKind.daily.rawValue
    }

    private func buildThreads() {
        var top = contentStack.topAnchor
        let tools = NSView()
        let filter = makeFilterStrip(
            labels: AgentsThreadFilter.allCases.map(\.label),
            selected: threadFilter.rawValue,
            action: #selector(threadFilterChanged(_:)))
        filter.setAccessibilityLabel("Filter threads")
        let create = NSButton(title: "+", target: self,
                              action: #selector(newThreadTapped))
        create.bezelStyle = .rounded
        create.controlSize = .small
        create.setAccessibilityLabel("New conversation")
        for view in [filter, create] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tools.addSubview(view)
        }
        NSLayoutConstraint.activate([
            filter.leadingAnchor.constraint(equalTo: tools.leadingAnchor),
            filter.topAnchor.constraint(equalTo: tools.topAnchor),
            filter.bottomAnchor.constraint(equalTo: tools.bottomAnchor),
            create.leadingAnchor.constraint(equalTo: filter.trailingAnchor, constant: 7),
            create.trailingAnchor.constraint(equalTo: tools.trailingAnchor),
            create.centerYAnchor.constraint(equalTo: filter.centerYAnchor),
            create.widthAnchor.constraint(equalToConstant: 32),
        ])
        place(tools, below: &top, gap: 7)

        let rows = dataSource?.agentSessionRows() ?? []
        let sections = AgentsThreadProjection.sections(
            threadProjectionInputs(), for: threadFilter)
        for section in sections {
            let ids = Set(section.rows.map(\.id))
            let members = rows.filter { row in
                ids.contains(AgentsThreadID(
                    source: row.kind == .assistant ? .assistant : .mcp,
                    value: row.id))
            }.sorted { lhs, rhs in
                let lhsID = AgentsThreadID(
                    source: lhs.kind == .assistant ? .assistant : .mcp, value: lhs.id)
                let rhsID = AgentsThreadID(
                    source: rhs.kind == .assistant ? .assistant : .mcp, value: rhs.id)
                return (section.rows.firstIndex { $0.id == lhsID } ?? .max)
                    < (section.rows.firstIndex { $0.id == rhsID } ?? .max)
            }
            guard !members.isEmpty else { continue }
            place(sectionHeader(section.group.label.uppercased(), count: members.count),
                  below: &top, gap: 12)
            for row in members {
                let id = AgentsThreadID(
                    source: row.kind == .assistant ? .assistant : .mcp,
                    value: row.id)
                let parts = (row.owner == row.name ? [] : [row.owner])
                    + [threadEvidence(row), row.preview]
                let view = makeRow(
                    leading: leadingIcon(for: row), name: row.name,
                    unread: row.unread || row.pendingAsk,
                    preview: parts.filter { !$0.isEmpty }.joined(separator: " · "),
                    time: row.updatedAt == .distantPast
                        ? row.time : Self.relativeTime(row.updatedAt),
                    action: row.pendingAsk && !row.archived ? "Reply" : nil)
                view.rowAction = .thread(id)
                place(view, below: &top, gap: 6)
            }
        }
        if sections.isEmpty {
            let copy: String
            switch threadFilter {
            case .open: copy = "No open threads\nStart a conversation"
            case .needs: copy = "Nothing needs you"
            case .unread: copy = "You're caught up"
            case .live: copy = "Nothing live"
            case .done: copy = "No completed threads"
            }
            let empty = NSTextField(wrappingLabelWithString: copy)
            empty.font = .systemFont(ofSize: 12.5, weight: .medium)
            empty.textColor = Theme.text3
            empty.alignment = .center
            place(empty, below: &top, gap: 28)
        }
        finishContent(top)
    }

    private func threadEvidence(_ row: AgentSessionRow) -> String {
        if row.archived { return "completed" }
        if row.pendingAsk { return "needs your reply" }
        if row.unread { return "unread" }
        if row.live { return row.kind == .assistant ? "working" : "live" }
        if row.ghost { return "ended" }
        return "recent"
    }

    private func makeNowRow(_ item: AgentsNowItem) -> AgentListRowView {
        let leading: NSView
        switch item.objectID {
        case .thread(let id):
            if let row = dataSource?.agentSessionRows().first(where: {
                $0.id == id.value
                    && ($0.kind == .assistant) == (id.source == .assistant)
            }) {
                leading = leadingIcon(for: row)
            } else {
                leading = circled(symbolIcon("text.bubble", description: "thread",
                                             pointSize: 12))
            }
        case .automation(let id):
            let state = dataSource?.agentJobRows().first(where: { $0.id == id })?.state ?? .failed
            leading = jobStateIcon(state)
        case .assistant:
            leading = circled(WaveformIconView())
        }
        // A session's label doubles as its owner — repeating it reads as
        // "tickets — VF53 · tickets — VF53".
        var parts = item.owner == item.title ? [item.summary]
            : [item.owner, item.summary]
        parts.append(Self.relativeTime(item.updatedAt))
        let verb: String?
        switch item.kind {
        case .pendingAsk: verb = "Reply"
        case .blockedAutomation, .failedAutomation: verb = "Review"
        case .runningAutomation, .runningThread: verb = nil
        case .unreadThread: verb = "Read"
        }
        var progress: Double?
        if case .automation(let jobID) = item.objectID, item.kind == .runningAutomation,
           let job = dataSource?.agentJobRows().first(where: { $0.id == jobID }) {
            progress = jobProgress(job)
        }
        let view = makeRow(
            leading: leading, name: item.title,
            unread: item.needsAttention || item.kind == .unreadThread,
            preview: parts.filter { !$0.isEmpty }.joined(separator: " · "),
            time: "", action: verb, progress: progress)
        view.rowAction = .object(item.objectID)
        return view
    }

    private func sectionHeader(_ title: String, count: Int?) -> NSView {
        let value = count.map { "\(title)  \($0)" } ?? title
        let text = NSTextField(labelWithString: value)
        let attributed = NSMutableAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: Theme.text3,
            .kern: 0.8,
        ])
        if count != nil {
            attributed.addAttribute(
                .foregroundColor, value: Theme.accent,
                range: NSRange(location: title.count + 2,
                               length: value.count - title.count - 2))
        }
        text.attributedStringValue = attributed
        text.setAccessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        return text
    }

    private func makeFilterStrip(labels: [String], selected: Int,
                                 action: Selector) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 3
        for (index, label) in labels.enumerated() {
            let button = NSButton(title: label, target: self, action: action)
            button.tag = index
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: index == selected ? .semibold : .medium)
            button.contentTintColor = index == selected ? Theme.text : Theme.text3
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            button.layer?.backgroundColor = index == selected
                ? Theme.cardHover.cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = index == selected ? 0.7 : 0
            button.layer?.borderColor = Theme.borderHover.cgColor
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.setAccessibilityLabel("\(label) filter\(index == selected ? ", selected" : "")")
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func emptyLabel(_ value: String) -> NSView {
        let text = NSTextField(labelWithString: value)
        text.font = .systemFont(ofSize: 12)
        text.textColor = Theme.text3
        text.alignment = .center
        return text
    }

    private func finishContent(_ top: NSLayoutYAxisAnchor) {
        let bottom = top.constraint(equalTo: contentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    private func buildSearch() {
        var top = contentStack.topAnchor
        let field = NSTextField()
        field.placeholderString = "Search assistants, automations, and threads"
        field.stringValue = searchQuery
        applyPaddedCell(field, fontSize: 12.5)
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10).cgColor
        field.layer?.cornerRadius = 8
        field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        field.delegate = self
        field.setAccessibilityLabel("Search assistants, automations, and threads")
        searchField = field
        place(field, below: &top, gap: 8)

        let documents = searchDocuments()
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let hint = emptyLabel("Type to search every Agents destination")
            place(hint, below: &top, gap: 24)
        } else {
            let results = AgentsSearchIndex.search(searchQuery, in: documents)
            if results.isEmpty {
                place(emptyLabel("No results for “\(searchQuery)”"), below: &top, gap: 24)
            } else {
                for result in results {
                    let icon: NSView
                    switch result.objectID {
                    case .assistant: icon = WaveformIconView()
                    case .automation: icon = symbolIcon("clock.arrow.circlepath", description: "automation")
                    case .thread(let id):
                        if id.source == .assistant { icon = WaveformIconView() }
                        else { icon = symbolIcon("text.bubble", description: "thread") }
                    }
                    let row = makeRow(
                        leading: icon, name: result.primaryText, unread: false,
                        preview: "\(result.destination.label) · \(result.secondaryText)", time: "")
                    row.rowAction = .object(result.objectID)
                    place(row, below: &top, gap: 6)
                }
            }
        }
        finishContent(top)
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, case .search = self.mode else { return }
            self.window?.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        }
    }

    private func searchDocuments() -> [AgentsSearchDocument] {
        var documents: [AgentsSearchDocument] = []
        for assistant in dataSource?.agentAssistantRows() ?? [] {
            documents.append(AgentsSearchDocument(
                objectID: .assistant(slug: assistant.slug), primaryText: assistant.name,
                secondaryText: assistant.description, indexText: assistant.description,
                updatedAt: assistant.updatedAt ?? .distantPast))
        }
        for job in dataSource?.agentJobRows() ?? [] {
            documents.append(AgentsSearchDocument(
                objectID: .automation(jobID: job.id), primaryText: job.name,
                secondaryText: job.assistantName, indexText: job.prompt,
                updatedAt: job.updatedAt))
        }
        for row in dataSource?.agentSessionRows() ?? [] {
            let id = AgentsThreadID(
                source: row.kind == .assistant ? .assistant : .mcp,
                value: row.id)
            let messageText = dataSource?.agentThreadDetail(for: id)?.messages
                .map { [$0.text, $0.hint].compactMap { $0 }.joined(separator: " ") }
                .joined(separator: " ") ?? ""
            documents.append(AgentsSearchDocument(
                objectID: .thread(id),
                primaryText: row.name, secondaryText: row.owner,
                indexText: "\(row.preview) \(messageText)", updatedAt: row.updatedAt))
        }
        return documents
    }

    /// The leading slot carries the session's state (design/agent-row-icons
    /// option A): connected = ⌃⌥ number in an amber ring, ghost = bare
    /// muted number, completed = quiet outlined check. No text suffixes.
    private func leadingIcon(for row: AgentSessionRow) -> NSView {
        if row.kind == .assistant {
            if let number = row.number { return RingNumberView(number: number, side: 24) }
            return circled(WaveformIconView())
        }
        if row.pendingAsk {
            let ask = symbolIcon("questionmark.bubble", description: "waiting question",
                                 pointSize: 12)
            (ask as? NSImageView)?.contentTintColor = Theme.accent
            return circled(ask)
        }
        guard let number = row.number else {
            return circled(symbolIcon("checkmark.circle", description: "completed",
                                      pointSize: 12))
        }
        if row.ghost {
            let label = NSTextField(labelWithString: "\(number)")
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = Theme.text3
            return circled(label)
        }
        return RingNumberView(number: number, side: 24)
    }

    private func makeRow(leading: NSView, name: String, unread: Bool,
                         preview: String, time: String,
                         action: String? = nil,
                         stats: String? = nil,
                         progress: Double? = nil) -> AgentListRowView {
        let row = AgentListRowView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.backgroundColor = Theme.card.cgColor
        row.layer?.borderWidth = 1
        row.layer?.borderColor = Theme.border.cgColor
        // Single-line cards at a fixed height; the detail carries the rest.
        // The metadata still surfaces on hover.
        let details = [preview, stats].compactMap { $0 }.filter { !$0.isEmpty }
        row.toolTip = details.isEmpty ? nil : details.joined(separator: "\n")
        row.setAccessibilityLabel(name)
        row.setAccessibilityHelp(([unread ? "Unread" : "", time] + details)
            .filter { !$0.isEmpty }.joined(separator: ". "))
        row.onActivate = { [weak self, weak row] in
            guard let row else { return }
            self?.activateRow(row)
        }

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13.5, weight: unread ? .semibold : .medium)
        nameLabel.textColor = Theme.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        // Long titles must truncate, never stretch the panel.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let trailing: NSView
        if let action {
            let verb = NSTextField(labelWithString: "\(action) ›")
            verb.font = .systemFont(ofSize: 12.5, weight: .medium)
            verb.textColor = Theme.accent
            trailing = verb
        } else {
            let timeLabel = NSTextField(labelWithString: time)
            timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            timeLabel.textColor = Theme.text3
            trailing = timeLabel
        }
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [leading, nameLabel, trailing] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 36),

            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: 24),

            nameLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 42),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -8),

            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        row.addGestureRecognizer(click)
        return row
    }

    /// The mock's leading icon: a thin amber-dim circle enclosing the glyph.
    private func circled(_ inner: NSView, diameter: CGFloat = 24) -> NSView {
        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.cornerRadius = diameter / 2
        circle.layer?.borderWidth = 1.3
        circle.layer?.borderColor = Theme.accentDim.cgColor
        circle.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(inner)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: diameter),
            circle.heightAnchor.constraint(equalToConstant: diameter),
            inner.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
        ])
        return circle
    }

    /// Compact relative age for row metadata ("asked 4m ago" territory).
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }

    @objc private func rowClicked(_ gesture: NSClickGestureRecognizer) {
        _ = (gesture.view as? AgentListRowView)?.performActivation()
    }

    private func activateRow(_ row: AgentListRowView) {
        guard let action = row.rowAction else { return }
        switch action {
        case .newAssistantIdentity:
            currentDestination = .assistants
            mode = .assistantCreate
            inlineError = nil
            rebuild()
        case .newAssistant:
            if let slug = dataSource?.agentAssistantRows().first(where: \.isDefault)?.slug {
                do {
                    if let id = try dataSource?.createAgentAssistantConversation(slug: slug) {
                        openThread(AgentsThreadID(source: .assistant, value: id))
                    }
                } catch {
                    threadInlineError = error.localizedDescription
                    rebuild()
                }
            } else {
                onNewAssistant?()
            }
        case .newAssistantConversation(let slug):
            do {
                let id = try dataSource?.createAgentAssistantConversation(slug: slug)
                inlineError = nil
                if let id {
                    openThread(AgentsThreadID(source: .assistant, value: id))
                }
            } catch {
                inlineError = error.localizedDescription
                rebuild()
            }
        case .newJob:
            currentDestination = .automations
            mode = .automationCreate
            inlineError = nil
            rebuild()
        case .assistant(let id):
            openThread(AgentsThreadID(source: .assistant, value: id))
        case .mcp(let id):
            openThread(AgentsThreadID(source: .mcp, value: id))
        case .thread(let id):
            openThread(id)
        case .job(let id):
            currentDestination = .automations
            mode = .job(id)
            rebuild()
        case .assistantWorkspace(let slug):
            currentDestination = .assistants
            mode = .assistantWorkspace(slug, .overview)
            inlineError = nil
            rebuild()
        case .systemAgent(let kind):
            currentDestination = .assistants
            mode = .systemAgent(kind)
            inlineError = nil
            systemAgentTestResult = nil
            rebuild()
        case .object(let objectID):
            open(objectID)
        }
    }

    private func open(_ objectID: AgentsObjectID) {
        pushedOrigin = mode
        switch objectID {
        case .assistant(let slug):
            currentDestination = .assistants
            mode = .assistantWorkspace(slug, .overview)
            rebuild()
        case .automation(let id):
            currentDestination = .automations
            mode = .job(id)
            rebuild()
        case .thread(let id):
            currentDestination = .threads
            openThread(id)
        }
    }

    private func symbolIcon(_ name: String, description: String,
                            pointSize: CGFloat = 12) -> NSView {
        let image = NSImageView(image: NSImage(
            systemSymbolName: name, accessibilityDescription: description) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        image.contentTintColor = Theme.text3
        return image
    }

    private func jobStateIcon(_ state: AgentJobState) -> NSView {
        let symbol: String
        switch state {
        case .running: symbol = "bolt.circle.fill"
        case .blocked, .failed: symbol = "exclamationmark.circle.fill"
        case .queued: symbol = "clock.fill"
        case .completed: symbol = "checkmark.circle"
        case .cancelled, .disabled: symbol = "pause.circle"
        }
        let view = symbolIcon(symbol, description: "automation \(state.rawValue)",
                              pointSize: 12)
        (view as? NSImageView)?.contentTintColor = state == .blocked || state == .failed
            ? Theme.accent : Theme.text3
        return circled(view)
    }

    /// Elapsed fraction of the active run against its maximum duration —
    /// the honest signal available for the mock's progress bar.
    private func jobProgress(_ job: AgentJobRow) -> Double? {
        guard job.isEnabled, job.state == .running,
              let run = job.runs.first(where: { $0.state == .running }),
              job.maxDurationSeconds > 0 else { return nil }
        return Date().timeIntervalSince(run.startedAt) / job.maxDurationSeconds
    }

    private func runStateIcon(_ state: AgentRunState) -> NSView {
        let symbol: String
        switch state {
        case .running: symbol = "bolt.circle.fill"
        case .completed: symbol = "checkmark.circle"
        case .failed: symbol = "exclamationmark.circle.fill"
        case .interrupted: symbol = "exclamationmark.arrow.circlepath"
        case .cancelled: symbol = "stop.circle"
        }
        let view = symbolIcon(symbol, description: "run \(state.rawValue)")
        (view as? NSImageView)?.contentTintColor = state == .failed || state == .interrupted
            ? Theme.accent : Theme.text3
        return view
    }

    private func buildThread(_ id: AgentsThreadID) {
        guard let detail = dataSource?.agentThreadDetail(for: id) else {
            var top = contentStack.topAnchor
            place(emptyLabel("No longer available"), below: &top, gap: 28)
            finishContent(top)
            return
        }
        var top = contentStack.topAnchor

        let header = NSView()
        let back = NSButton(title: "‹", target: self, action: #selector(backTapped))
        back.isBordered = false
        back.font = .systemFont(ofSize: 16, weight: .medium)
        back.contentTintColor = Theme.text2
        let title = NSTextField(labelWithString: detail.title)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let state = NSTextField(labelWithString: detail.owner == detail.title
            ? detail.state : "\(detail.owner) · \(detail.state)")
        state.font = .systemFont(ofSize: 10.5)
        state.textColor = detail.live ? Theme.accent : Theme.text3
        state.lineBreakMode = .byTruncatingTail
        state.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, state])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let lifecycle = NSButton(
            image: NSImage(systemSymbolName: detail.archived ? "arrow.uturn.backward.circle" : "checkmark.circle",
                           accessibilityDescription: detail.archived ? "Reopen thread" : "Complete thread") ?? NSImage(),
            target: self, action: #selector(threadLifecycleTapped))
        lifecycle.isBordered = false
        lifecycle.contentTintColor = Theme.text3
        lifecycle.isEnabled = detail.archived || detail.canComplete
        lifecycle.toolTip = detail.archived ? "Reopen thread" : "Complete thread"

        let speak = NSButton(
            image: NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Read thread aloud") ?? NSImage(),
            target: self, action: #selector(speakTapped))
        speak.isBordered = false
        speak.contentTintColor = Theme.text3
        speak.isHidden = !detail.canSpeak

        let delete = NSButton(
            image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete thread") ?? NSImage(),
            target: self, action: #selector(deleteThreadTapped))
        delete.isBordered = false
        delete.contentTintColor = Theme.text3
        delete.isEnabled = detail.canDelete
        delete.toolTip = detail.linkedAutomationCount > 0
            ? "Used by \(detail.linkedAutomationCount) automation\(detail.linkedAutomationCount == 1 ? "" : "s")"
            : "Delete thread permanently"

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor
        for view in [back, labels, lifecycle, speak, delete, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -3),
            labels.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 7),
            labels.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -3),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: lifecycle.leadingAnchor, constant: -7),
            lifecycle.trailingAnchor.constraint(equalTo: speak.leadingAnchor, constant: -6),
            lifecycle.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
            speak.trailingAnchor.constraint(equalTo: delete.leadingAnchor, constant: -6),
            speak.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
            delete.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -3),
            delete.centerYAnchor.constraint(equalTo: labels.centerYAnchor),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            header.heightAnchor.constraint(equalToConstant: 48),
        ])
        installThreadHeader(header)

        if threadCompleteConfirmationID == id {
            let confirmation = NSView()
            let copy = NSTextField(labelWithString: "Completing cancels its waiting question.")
            copy.font = .systemFont(ofSize: 11.5, weight: .medium)
            copy.textColor = Theme.text
            let cancel = NSButton(title: "Cancel", target: self,
                                  action: #selector(cancelCompleteThreadTapped))
            let confirm = NSButton(title: "Complete", target: self,
                                   action: #selector(confirmCompleteThreadTapped))
            confirm.contentTintColor = Theme.accent
            for view in [copy, cancel, confirm] {
                view.translatesAutoresizingMaskIntoConstraints = false
                confirmation.addSubview(view)
            }
            NSLayoutConstraint.activate([
                copy.leadingAnchor.constraint(equalTo: confirmation.leadingAnchor, constant: 4),
                copy.centerYAnchor.constraint(equalTo: confirmation.centerYAnchor),
                cancel.leadingAnchor.constraint(greaterThanOrEqualTo: copy.trailingAnchor, constant: 8),
                confirm.leadingAnchor.constraint(equalTo: cancel.trailingAnchor, constant: 6),
                confirm.trailingAnchor.constraint(equalTo: confirmation.trailingAnchor),
                cancel.centerYAnchor.constraint(equalTo: confirmation.centerYAnchor),
                confirm.centerYAnchor.constraint(equalTo: confirmation.centerYAnchor),
                confirmation.heightAnchor.constraint(equalToConstant: 34),
            ])
            place(confirmation, below: &top, gap: 6)
        }

        if threadDeleteConfirmationID == id {
            let confirmation = NSView()
            let copy = NSTextField(labelWithString: "Delete permanently?")
            copy.font = .systemFont(ofSize: 11.5, weight: .medium)
            copy.textColor = Theme.text
            let cancel = NSButton(title: "Cancel", target: self,
                                  action: #selector(cancelDeleteThreadTapped))
            let confirm = NSButton(title: "Delete", target: self,
                                   action: #selector(confirmDeleteThreadTapped))
            confirm.contentTintColor = Theme.accent
            for view in [copy, cancel, confirm] {
                view.translatesAutoresizingMaskIntoConstraints = false
                confirmation.addSubview(view)
            }
            NSLayoutConstraint.activate([
                copy.leadingAnchor.constraint(equalTo: confirmation.leadingAnchor, constant: 4),
                copy.centerYAnchor.constraint(equalTo: confirmation.centerYAnchor),
                cancel.leadingAnchor.constraint(greaterThanOrEqualTo: copy.trailingAnchor, constant: 8),
                confirm.leadingAnchor.constraint(equalTo: cancel.trailingAnchor, constant: 6),
                confirm.trailingAnchor.constraint(equalTo: confirmation.trailingAnchor),
                cancel.centerYAnchor.constraint(equalTo: confirmation.centerYAnchor),
                confirm.centerYAnchor.constraint(equalTo: confirmation.centerYAnchor),
                confirmation.heightAnchor.constraint(equalToConstant: 34),
            ])
            place(confirmation, below: &top, gap: 6)
        }

        if let error = threadInlineError {
            place(errorLabel(error), below: &top, gap: 8)
        }

        var renderedMessages = detail.messages
        if id.source == .assistant,
           let streaming = assistantThreadStreams[id.value] {
            renderedMessages.append(AgentThreadMessage(
                id: "stream:\(id.value)", at: Date(), role: .assistant,
                text: streaming, hint: nil))
        }
        if threadRowCacheThread != id {
            threadRowCache.removeAll()
            threadRowCacheThread = id
        }
        var liveRowIDs = Set<String>()
        for (index, message) in renderedMessages.enumerated() {
            let roleText: String = {
                switch message.role {
                case .assistant: return detail.owner.uppercased()
                case .user: return "YOU"
                case .note: return "NOTE"
                }
            }()
            let bodyText = [message.text, message.hint]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let shownBody = bodyText.isEmpty && message.id.hasPrefix("stream:") ? "…" : bodyText
            let row = threadRowCache[message.id] ?? ThreadMessageRow()
            threadRowCache[message.id] = row
            liveRowIDs.insert(message.id)
            row.apply(roleText: roleText,
                      roleColor: message.role == .user ? Theme.accent : Theme.text3,
                      bodyText: shownBody,
                      bodyColor: message.role == .note ? Theme.text3 : Theme.text2,
                      key: "\(message.role)\u{1}\(roleText)\u{1}\(shownBody)")
            row.dividerHeight.constant = index == renderedMessages.count - 1 ? 0 : 1
            if message.id.hasPrefix("stream:") { assistantThreadStreamingLabel = row.body }
            place(row, below: &top, gap: 0)
        }
        threadRowCache = threadRowCache.filter { liveRowIDs.contains($0.key) }

        if detail.messages.isEmpty {
            place(emptyLabel("No messages yet"), below: &top, gap: 24)
        }

        let assistantThread = id.source == .assistant
        if detail.archived {
            place(emptyLabel("Reopen this thread to reply"), below: &top, gap: 14)
        } else if detail.canReply || (assistantThread && detail.live) {
            let composer: ComposerView
            if let existing = composerField, composerThreadID == id {
                composer = existing
            } else {
                composer = makeComposer(
                    placeholder: assistantThread ? "Message \(detail.owner)…" : "Message this thread…")
                composer.text = threadDrafts[id] ?? ""
                composer.attachments = threadAttachments[id] ?? []
            }
            if assistantThread { configureAssistantComposer(composer, detail: detail) }
            installComposer(composer)
            composer.setRecording(recordingActive)
            composer.onAttachRequested = { [weak self] in self?.pickAttachments() }
            composerField = composer
            composerThreadID = id
            if assistantThread {
                assistantActivity = detail.live && detail.activity == .idle ? .thinking : detail.activity
                applyAssistantActivity()
            }
        } else if let reason = detail.readOnlyReason {
            let notice = NSTextField(wrappingLabelWithString: reason)
            notice.font = .systemFont(ofSize: 11.5)
            notice.textColor = Theme.text3
            notice.alignment = .center
            place(notice, below: &top, gap: 14)
        }

        finishContent(top)
    }

    private func applyAssistantActivity() {
        let text: String
        switch assistantActivity {
        case .idle: text = ""
        case .thinking: text = assistantActivityDetail ?? "Thinking…"
        case .responding: text = assistantActivityDetail ?? "Replying…"
        case .acting: text = assistantActivityDetail ?? "Working on your screen…"
        }
        composerField?.setStatus(text, running: assistantActivity != .idle)
    }

    /// The agent's activity for `conversationID`, from AppDelegate. Updates
    /// the status row in place — only when that conversation is the open
    /// thread; another conversation's turn must not paint over this one.
    /// The rebuild at turn end comes through the history change (rows flip
    /// running → idle), via the panel's visibility-guarded refresh.
    func setAssistantActivity(_ activity: AgentActivity, detail: String? = nil,
                              conversationID: String) {
        guard case .thread(let id) = mode, id.source == .assistant,
              id.value == conversationID else { return }
        if activity != assistantActivity { assistantActivityDetail = nil }
        assistantActivity = activity
        if let detail { assistantActivityDetail = detail }
        applyAssistantActivity()
    }

    /// One-line app notice ("Sent to Claude.", "Stopped by Escape") shown
    /// briefly at the bottom of the Agents surface, whatever it shows.
    func showTransientNote(_ text: String) {
        transientNoteTimer?.invalidate()
        let label: NSTextField
        if let existing = transientNoteLabel {
            label = existing
        } else {
            label = PassThroughLabel(labelWithString: "")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = Theme.text
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            // A long notice truncates; it must never widen the panel.
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.wantsLayer = true
            label.layer?.backgroundColor = Theme.cardHover.cgColor
            label.layer?.cornerRadius = 8
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.bottomAnchor.constraint(equalTo: composerHost.topAnchor, constant: -8),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
                label.heightAnchor.constraint(equalToConstant: 24),
            ])
            transientNoteLabel = label
        }
        label.stringValue = "  \(text)  "
        label.toolTip = text
        label.isHidden = false
        transientNoteTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            self?.transientNoteLabel?.isHidden = true
        }
    }

    func focusComposer() { composerField?.focus() }

    /// A dictation into the open thread started or ended: the mic reflects it.
    func setRecording(_ on: Bool) {
        recordingActive = on
        composerField?.setRecording(on)
    }

    /// A non-modal picker belongs to the thread that opened it, including
    /// when the user navigates before choosing the files.
    private func pickAttachments() {
        guard let originID = composerThreadID else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        picker.message = "Attach images to this message"
        // The chat panel floats above normal windows; a non-modal open panel
        // opens at normal level and lands behind it. Sit one level higher.
        picker.level = (window?.level ?? .floating) + 1
        attachPicker = picker
        picker.begin { [weak self] response in
            guard response == .OK, let self else { return }
            self.acceptPickedAttachments(picker.urls.map(\.path), for: originID)
        }
    }

    func acceptPickedAttachments(_ paths: [String], for originID: AgentsThreadID) {
        guard dataSource?.agentThreadDetail(for: originID) != nil else { return }
        if composerThreadID == originID, let composer = composerField {
            for path in paths { composer.addAttachment(path: path) }
            threadAttachments[originID] = composer.attachments
            composer.focus()
        } else {
            threadAttachments[originID, default: []].append(contentsOf: paths)
        }
    }

#if VOICE_FLOW_QA
    var qaAssistantControlState: [String: Any] {
        let runtime = composerField?.runtimeControl
        let controls: [NSControl] = [runtime, composerField?.modelControl, composerField?.effortControl, composerField?.accessControl,
                                     composerField?.micControl, composerField?.stopControl].compactMap { $0 }
        return [
            "runtime_present": runtime != nil,
            "access_mode": composerField?.accessControl?.titleOfSelectedItem ?? "",
            "model_title": composerField?.modelControl?.titleOfSelectedItem ?? "",
            "runtime_enabled": runtime?.isEnabled ?? false,
            "runtime_title": runtime?.titleOfSelectedItem ?? "",
            "composer_running": composerField?.isRunning ?? false,
            "composer_status": composerField?.status ?? "",
            "accessibility_labels": controls.compactMap {
                $0.accessibilityLabel()?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty },
        ]
    }
#endif

    /// The assistant composer's session bar: access mode, attach, mic, snap
    /// on the left; runtime (or the review-copies notice) and effort on the
    /// right. Every control passes the thread it sits in.
    private func configureAssistantComposer(_ composer: ComposerView, detail: AgentThreadDetail) {
        var controls = ComposerControls()
        controls.accessOptions = AgentCapabilityDial.AccessMode.allCases.map(\.label)
        controls.accessIndex = UserSettings.shared.agentCapabilityDial.accessMode.rawValue
        controls.attach = true
        controls.mic = detail.canSnap
        if detail.sourceReviewOnly {
            controls.runtimeOptions = ["Review copies · OpenRouter"]
            controls.runtimeIndex = 0
            controls.runtimeEnabled = false
        } else {
            controls.runtimeOptions = AgentRuntimeKind.allCases.map(\.label)
            controls.runtimeIndex = AgentRuntimeKind.allCases.firstIndex(of: detail.runtime ?? .codex) ?? 0
            controls.runtimeEnabled = detail.runtimeSwitchable
        }
        let runtimeKind = detail.runtime ?? .codex
        let models = modelChoices(for: runtimeKind, current: detail.model)
        if !detail.sourceReviewOnly {
            controls.modelOptions = models.map(\.label)
            controls.modelIndex = models.firstIndex { $0.value == detail.model } ?? 0
        }
        controls.effortOptions = AgentReasoningEffort.choices.map(\.label)
        let effort = AgentReasoningEffort.normalized(UserSettings.shared.agentReasoningEffort)
            ?? AgentReasoningEffort.unset
        controls.effortIndex = AgentReasoningEffort.choices.firstIndex { $0.value == effort } ?? 0
        controls.snap = detail.canSnap
        composer.setControls(controls)
        composer.onModelSelected = { [weak self] index in
            guard let self, let id = self.openThreadID, models.indices.contains(index) else { return }
            self.onSelectModel?(runtimeKind, models[index].value, id)
        }
        composer.onRuntimeSelected = { [weak self] index in
            guard let self, let id = self.openThreadID,
                  AgentRuntimeKind.allCases.indices.contains(index) else { return }
            self.onSelectAssistantRuntime?(AgentRuntimeKind.allCases[index], id)
        }
        composer.onEffortSelected = { [weak self] index in
            guard AgentReasoningEffort.choices.indices.contains(index) else { return }
            self?.onSelectReasoningEffort?(AgentReasoningEffort.choices[index].value)
        }
        composer.onSnap = { [weak self] in
            if let id = self?.openThreadID { self?.onSnap?(id) }
        }
        composer.onStop = { [weak self] in
            if let id = self?.openThreadID { self?.onStop?(id) }
        }
        composer.onAccessSelected = { [weak self] index in
            guard let mode = AgentCapabilityDial.AccessMode(rawValue: index) else { return }
            self?.onSelectAccessMode?(mode)
        }
        composer.onMicToggle = { [weak self] in
            if let id = self?.openThreadID { self?.onMicToggle?(id) }
        }
    }

    /// What the model popup offers for a runtime: the runtime's own default
    /// first, then what it can run. A currently chosen value that is not in
    /// the list (typed in Settings) is kept as its own entry.
    private func modelChoices(for kind: AgentRuntimeKind, current: String) -> [(value: String, label: String)] {
        var choices: [(value: String, label: String)]
        if let cached = modelChoicesCache[kind], Date().timeIntervalSince(cached.at) < 60 {
            choices = cached.choices
        } else {
            switch kind {
            case .codex:
                choices = [("", "Codex default")] + CodexModelCatalog.installedSlugs().map { ($0, $0) }
            case .claude:
                choices = [("", "Claude default")] + ClaudeModelCatalog.choices()
                ClaudeModelCatalog.refreshIfStale()
            case .opencode:
                let catalog = (dataSource?.agentAutomationModels() ?? [])
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                choices = catalog.map { ($0.id, $0.name) }
            }
            modelChoicesCache[kind] = (Date(), choices)
        }
        if !current.isEmpty, !choices.contains(where: { $0.value == current }) {
            choices.insert((current, kind == .claude ? ClaudeModelCatalog.label(for: current) : current),
                           at: kind == .opencode ? 0 : 1)
        }
        // Index 0 ("") means "no per-conversation choice": the turn runs on
        // the Settings model when one is set, else the CLI's own default.
        // Say which, or picking it looks like a dead item.
        let global: String = {
            switch kind {
            case .codex: return UserSettings.shared.codexModel
            case .claude: return UserSettings.shared.claudeCodeModel
            case .opencode: return ""
            }
        }()
        if kind != .opencode, let first = choices.first, first.value.isEmpty, !global.isEmpty {
            choices[0] = ("", "Default (\(kind == .claude ? ClaudeModelCatalog.label(for: global) : global))")
        } else if kind == .claude, let first = choices.first, first.value.isEmpty,
                  let cliDefault = ClaudeModelCatalog.resolved(for: nil) {
            choices[0] = ("", "Claude default · \(cliDefault)")
        }
        return choices
    }

    private func makeComposer(placeholder: String) -> ComposerView {
        let composer = ComposerView(placeholder: placeholder, fontSize: 12.5)
        composer.onSend = { [weak self] text, images in self?.submit(text, images: images) }
        return composer
    }

    private func place(_ view: NSView, below top: inout NSLayoutYAxisAnchor, gap: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: top, constant: gap),
            view.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
        ])
        top = view.bottomAnchor
    }

    // ── Actions ─────────────────────────────────────────

    @objc private func destinationTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let destination = AgentsDestination(rawValue: raw) else { return }
        currentDestination = destination
        mode = .destination(destination)
        inlineError = nil
        assistantDeleteConfirmationSlug = nil
        automationDeleteConfirmationID = nil
        threadDeleteConfirmationID = nil
        threadCompleteConfirmationID = nil
        threadInlineError = nil
        pushedOrigin = nil
        rebuild()
    }

    @objc private func newThreadTapped() {
        if let slug = dataSource?.agentAssistantRows().first(where: \.isDefault)?.slug {
            do {
                if let id = try dataSource?.createAgentAssistantConversation(slug: slug) {
                    openThread(AgentsThreadID(source: .assistant, value: id))
                }
            } catch {
                threadInlineError = error.localizedDescription
                rebuild()
            }
        } else {
            onNewAssistant?()
        }
    }

    @objc private func threadFilterChanged(_ sender: NSButton) {
        threadFilter = AgentsThreadFilter(rawValue: sender.tag) ?? .open
        threadInlineError = nil
        rebuild()
    }

    @objc private func newAutomationTapped() {
        currentDestination = .automations
        mode = .automationCreate
        inlineError = nil
        automationDeleteConfirmationID = nil
        rebuild()
    }

    @objc private func automationFilterChanged(_ sender: NSButton) {
        automationFilter = AutomationFilter(rawValue: sender.tag) ?? .all
        rebuild()
    }

    @objc private func automationFormControlChanged() {
        updateAutomationFormAvailability()
    }

    @objc private func editAutomationTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        mode = .automationEdit(id)
        inlineError = nil
        automationDeleteConfirmationID = nil
        rebuild()
    }

    @objc private func saveAutomationTapped(_ sender: NSButton) {
        guard let dataSource else { return }
        let values = currentAutomationFormValues()
        guard let draft = automationDraft(from: values) else {
            rebuildPreservingAutomationForm(values)
            return
        }
        do {
            if let id = sender.identifier?.rawValue {
                try dataSource.updateAgentAutomation(id: id, draft: draft)
                clearWorkspaceDraft("automation:\(id)")
                mode = .job(id)
            } else {
                let id = try dataSource.createAgentAutomation(draft)
                clearWorkspaceDraft("automation:create")
                mode = .job(id)
            }
            inlineError = nil
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuildPreservingAutomationForm(values)
        }
    }

    @objc private func duplicateAutomationTapped(_ sender: NSButton) {
        guard let dataSource, let id = sender.identifier?.rawValue else { return }
        do {
            let duplicate = try dataSource.duplicateAgentAutomation(id: id)
            inlineError = nil
            mode = .job(duplicate)
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuild()
        }
    }

    @objc private func deleteAutomationTapped(_ sender: NSButton) {
        automationDeleteConfirmationID = sender.identifier?.rawValue
        inlineError = nil
        rebuild()
    }

    @objc private func cancelDeleteAutomationTapped() {
        automationDeleteConfirmationID = nil
        inlineError = nil
        rebuild()
    }

    @objc private func confirmDeleteAutomationTapped(_ sender: NSButton) {
        guard let dataSource, let id = sender.identifier?.rawValue,
              automationDeleteConfirmationID == id else { return }
        do {
            try dataSource.deleteAgentAutomation(id: id)
            automationDeleteConfirmationID = nil
            inlineError = nil
            mode = .destination(.automations)
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuild()
        }
    }

    @objc private func searchTapped() {
        mode = .search
        rebuild()
    }

    @objc private func backTapped() {
        if let origin = workspaceExternalOrigin {
            let returnsToSource: Bool
            switch (origin, mode) {
            case (.assistant(let slug), .assistantWorkspace(let current, _)): returnsToSource = slug == current
            case (.automation(let id), .automationEdit(let current)): returnsToSource = id == current
            case (.thread(let id), .thread(let current)): returnsToSource = id == current
            default: returnsToSource = false
            }
            if returnsToSource {
                workspaceExternalOrigin = nil
                onWorkspaceOriginBack?()
                return
            }
        }
        if let origin = pushedOrigin {
            mode = origin
            pushedOrigin = nil
        } else {
            mode = .destination(currentDestination)
        }
        inlineError = nil
        assistantDeleteConfirmationSlug = nil
        automationDeleteConfirmationID = nil
        threadDeleteConfirmationID = nil
        threadCompleteConfirmationID = nil
        threadInlineError = nil
        systemAgentTestResult = nil
        rebuild()
    }

    @objc private func assistantTabTapped(_ sender: NSButton) {
        guard case .assistantWorkspace(let slug, _) = mode,
              let raw = sender.identifier?.rawValue,
              let tab = AssistantWorkspaceTab(rawValue: raw) else { return }
        inlineError = nil
        mode = .assistantWorkspace(slug, tab)
        rebuild()
    }

    @objc private func assistantMemoryKindTapped(_ sender: NSButton) {
        guard let kind = sender.identifier?.rawValue,
              kind == "core" || kind == "ledger" else { return }
        assistantMemoryKind = kind
        inlineError = nil
        rebuild()
    }

    @objc private func createAssistantTapped() {
        guard let dataSource, let name = assistantNameField?.stringValue else { return }
        let draft = AssistantDraft(
            name: name,
            description: assistantDescriptionField?.stringValue ?? "",
            instructions: assistantInstructionsView?.string ?? "")
        do {
            let slug = try dataSource.createAgentAssistant(draft)
            clearWorkspaceDraft("assistant:create")
            inlineError = nil
            mode = .assistantWorkspace(slug, .overview)
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuildPreservingAssistantDraft()
        }
    }

    @objc private func manageSourcesTapped() { dataSource?.openAgentDataSources() }

#if VOICE_FLOW_QA
    func qaSourceSelection(_ payload: [String: Any]) -> [String: Any] {
        let selection = assistantSources ?? automationSources
        if let ids = payload["selected_source_ids"] as? [String] {
            selection?.select(ids: ids, mode: (payload["source_access_mode"] as? String)
                .flatMap(AgentSourceAccessMode.init(rawValue:)) ?? selection?.selectedMode ?? .standard)
        }
        if payload["save"] as? Bool == true {
            if case .assistantWorkspace(let slug, _) = mode,
               let snapshot = try? dataSource?.assistantWorkspace(slug: slug) {
                let sender = NSButton()
                sender.identifier = NSUserInterfaceItemIdentifier(snapshot.document.revision)
                saveAssistantSettingsTapped(sender)
            } else if case .automationEdit(let id) = mode {
                let sender = NSButton(); sender.identifier = NSUserInterfaceItemIdentifier(id)
                saveAutomationTapped(sender)
            }
        }
        if let visibleSelection = assistantSources ?? automationSources {
            layoutSubtreeIfNeeded()
            visibleSelection.scrollToVisible(visibleSelection.bounds)
        }
        return ["selected_source_ids": (assistantSources ?? automationSources)?.selectedIDs ?? [],
                "source_access_mode": (assistantSources ?? automationSources)?.selectedMode.rawValue ?? "",
                "error": inlineError ?? ""]
    }
#endif

    @objc private func saveAssistantSettingsTapped(_ sender: NSButton) {
        guard let dataSource,
              case .assistantWorkspace(let slug, _) = mode,
              let revision = assistantSettingsRevision,
              let snapshot = try? dataSource.assistantWorkspace(slug: slug) else { return }
        let draft = AssistantDraft(
            name: assistantNameField?.stringValue ?? snapshot.document.definition.name,
            description: assistantDescriptionField?.stringValue ?? snapshot.document.definition.description,
            voice: assistantVoiceField?.stringValue,
            instructions: assistantInstructionsView?.string ?? snapshot.document.definition.instructions,
            selectedSkills: snapshot.document.definition.selectedSkills,
            selectedSourceIDs: assistantSources?.selectedIDs ?? snapshot.document.definition.selectedSourceIDs,
            sourceAccessMode: assistantSources?.selectedMode ?? snapshot.document.definition.sourceAccessMode)
        do {
            try dataSource.updateAgentAssistant(
                slug: slug, draft: draft, expectedRevision: revision)
            clearWorkspaceDraft("assistant:\(slug):settings")
            inlineError = nil
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuildPreservingAssistantDraft()
        }
    }

    @objc private func saveAssistantMemoryTapped() {
        guard let dataSource,
              case .assistantWorkspace(let slug, _) = mode,
              let revision = assistantMemoryRevision,
              let content = assistantMemoryView?.string else { return }
        do {
            _ = try dataSource.updateAgentAssistantMemory(
                slug: slug, kind: assistantMemoryKind,
                content: content, expectedRevision: revision)
            clearWorkspaceDraft("assistant:\(slug):memory:\(assistantMemoryKind)")
            inlineError = nil
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuildPreservingAssistantDraft()
        }
    }

    @objc private func reloadAssistantSettingsTapped() {
        guard case .assistantWorkspace(let slug, _) = mode else { return }
        clearWorkspaceDraft("assistant:\(slug):settings")
        inlineError = nil
        rebuild()
    }

    @objc private func reloadAssistantMemoryTapped() {
        guard case .assistantWorkspace(let slug, _) = mode else { return }
        clearWorkspaceDraft("assistant:\(slug):memory:\(assistantMemoryKind)")
        inlineError = nil
        rebuild()
    }

    @objc private func reloadAssistantSkillsTapped() {
        guard case .assistantWorkspace(let slug, _) = mode else { return }
        clearWorkspaceDraft("assistant:\(slug):skills")
        inlineError = nil
        rebuild()
    }

    @objc private func saveAssistantSkillsTapped() {
        guard let dataSource,
              case .assistantWorkspace(let slug, _) = mode,
              let revision = assistantSkillsRevision,
              let snapshot = try? dataSource.assistantWorkspace(slug: slug) else { return }
        let selected = assistantSkillButtons
            .filter { $0.value.state == .on }
            .map(\.key).sorted()
        let definition = snapshot.document.definition
        let draft = AssistantDraft(
            name: definition.name, description: definition.description,
            voice: definition.voice, instructions: definition.instructions,
            selectedSkills: selected, selectedSourceIDs: definition.selectedSourceIDs,
            sourceAccessMode: definition.sourceAccessMode)
        do {
            try dataSource.updateAgentAssistant(
                slug: slug, draft: draft,
                expectedRevision: revision)
            clearWorkspaceDraft("assistant:\(slug):skills")
            inlineError = nil
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuildPreservingAssistantDraft()
        }
    }

    @objc private func duplicateAssistantTapped() {
        guard let dataSource,
              case .assistantWorkspace(let slug, _) = mode,
              let snapshot = try? dataSource.assistantWorkspace(slug: slug) else { return }
        do {
            let duplicate = try dataSource.duplicateAgentAssistant(
                slug: slug, name: snapshot.document.definition.name + " Copy")
            inlineError = nil
            mode = .assistantWorkspace(duplicate, .overview)
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuild()
        }
    }

    @objc private func deleteAssistantTapped() {
        guard case .assistantWorkspace(let slug, _) = mode else { return }
        assistantDeleteConfirmationSlug = slug
        inlineError = nil
        rebuild()
    }

    @objc private func cancelDeleteAssistantTapped() {
        assistantDeleteConfirmationSlug = nil
        inlineError = nil
        rebuild()
    }

    @objc private func confirmDeleteAssistantTapped() {
        guard let dataSource,
              case .assistantWorkspace(let slug, _) = mode,
              assistantDeleteConfirmationSlug == slug else { return }
        do {
            _ = try dataSource.deleteAgentAssistant(slug: slug)
            assistantDeleteConfirmationSlug = nil
            inlineError = nil
            mode = .destination(.assistants)
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuild()
        }
    }

    @objc private func runJobTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        dataSource?.runAgentJob(id)
        DispatchQueue.main.async { self.refresh() }
    }

    @objc private func cancelJobTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        dataSource?.cancelAgentJob(id)
        DispatchQueue.main.async { self.refresh() }
    }

    @objc private func toggleJobTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        dataSource?.setAgentJob(id, enabled: sender.tag == 1)
        DispatchQueue.main.async { self.refresh() }
    }

    @objc private func speakTapped(_ sender: NSButton) {
        guard case .thread(let id) = mode else { return }
        dataSource?.speakThread(id)
    }

    @objc private func threadLifecycleTapped() {
        guard let dataSource, case .thread(let id) = mode,
              let detail = dataSource.agentThreadDetail(for: id) else { return }
        // Completing cancels a waiting question — that must never ride on a
        // single click. A second ✓ press while the confirmation shows confirms.
        if !detail.archived, detail.pendingAsk, threadCompleteConfirmationID != id {
            threadCompleteConfirmationID = id
            threadDeleteConfirmationID = nil
            threadInlineError = nil
            rebuild()
            return
        }
        do {
            if detail.archived { try dataSource.reopenThread(id) }
            else { try dataSource.completeThread(id) }
            threadInlineError = nil
            threadDeleteConfirmationID = nil
            threadCompleteConfirmationID = nil
            threadFilter = detail.archived ? .open : .done
            mode = .destination(.threads)
            pushedOrigin = nil
            rebuild()
        } catch {
            threadInlineError = error.localizedDescription
            rebuild()
        }
    }

    @objc private func cancelCompleteThreadTapped() {
        threadCompleteConfirmationID = nil
        threadInlineError = nil
        rebuild()
    }

    @objc private func confirmCompleteThreadTapped() {
        guard let dataSource, case .thread(let id) = mode,
              threadCompleteConfirmationID == id else { return }
        do {
            try dataSource.completeThread(id)
            threadCompleteConfirmationID = nil
            threadInlineError = nil
            threadFilter = .done
            mode = .destination(.threads)
            pushedOrigin = nil
            rebuild()
        } catch {
            threadCompleteConfirmationID = nil
            threadInlineError = error.localizedDescription
            rebuild()
        }
    }

    @objc private func deleteThreadTapped() {
        guard case .thread(let id) = mode else { return }
        threadDeleteConfirmationID = id
        threadCompleteConfirmationID = nil
        threadInlineError = nil
        rebuild()
    }

    @objc private func cancelDeleteThreadTapped() {
        threadDeleteConfirmationID = nil
        threadInlineError = nil
        rebuild()
    }

    @objc private func confirmDeleteThreadTapped() {
        guard let dataSource, case .thread(let id) = mode,
              threadDeleteConfirmationID == id else { return }
        do {
            try dataSource.deleteThread(id)
            threadDeleteConfirmationID = nil
            threadInlineError = nil
            threadDrafts.removeValue(forKey: id)
            // Drop the field reference first or the rebuild-entry stash
            // resurrects the deleted thread's draft.
            composerField = nil
            composerThreadID = nil
            mode = .destination(.threads)
            pushedOrigin = nil
            rebuild()
        } catch {
            threadInlineError = error.localizedDescription
            rebuild()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === searchField {
            let value = field.stringValue
            guard value != searchQuery else { return }
            searchQuery = value
            DispatchQueue.main.async { [weak self] in
                guard let self, case .search = self.mode else { return }
                self.rebuild()
            }
        } else if field === automationSearchField {
            let value = field.stringValue
            guard value != automationSearchQuery else { return }
            automationSearchQuery = value
            DispatchQueue.main.async { [weak self] in
                guard let self, case .destination(.automations) = self.mode else { return }
                self.rebuild()
                self.automationSearchField?.window?.makeFirstResponder(
                    self.automationSearchField)
            }
        }
    }

    private func stashComposerDraft() {
        guard let composer = composerField, let id = composerThreadID else { return }
        threadDrafts[id] = composer.text
        threadAttachments[id] = composer.attachments
    }

    private func submit(_ text: String, images: [String] = []) {
        guard !text.isEmpty || !images.isEmpty,
              case .thread(let id) = mode, let dataSource else { return }
        threadDrafts[id] = text
        do {
            try dataSource.sendMessage(toThread: id, text: text, attachments: images)
            threadDrafts[id] = ""
            composerField?.clear()
            threadInlineError = nil
            DispatchQueue.main.async { self.refresh() }
        } catch {
            threadInlineError = error.localizedDescription
            rebuild()
        }
    }
}

private enum AgentListRowAction {
    case newAssistantIdentity
    case newAssistant
    case newAssistantConversation(String)
    case newJob
    case assistant(String)
    case mcp(String)
    case thread(AgentsThreadID)
    case job(String)
    case assistantWorkspace(String)
    case systemAgent(String)
    case object(AgentsObjectID)
}

private final class AgentListRowView: HoverRowView {
    var rowAction: AgentListRowAction?
    var onActivate: (() -> Void)?
    private var hovered = false
    private var keyboardFocused = false

    override var acceptsFirstResponder: Bool { rowAction != nil }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { rowAction == nil ? .group : .button }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityPerformPress() -> Bool { performActivation() }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        if selector == NSSelectorFromString("accessibilityPerformPress") { return rowAction != nil }
        return super.isAccessibilitySelectorAllowed(selector)
    }

    @discardableResult
    func performActivation() -> Bool {
        guard rowAction != nil, let onActivate else { return false }
        onActivate()
        return true
    }

    override func becomeFirstResponder() -> Bool {
        keyboardFocused = true
        updateAppearance()
        scrollToVisible(bounds)
        return true
    }

    override func resignFirstResponder() -> Bool {
        keyboardFocused = false
        updateAppearance()
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           [36, 49, 76].contains(event.keyCode), !event.isARepeat,
           performActivation() { return }
        super.keyDown(with: event)
    }

    // Rows are card surfaces: rest on Theme.card, brighten on hover.
    override func setHovered(_ hovered: Bool) {
        self.hovered = hovered
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = hovered || keyboardFocused ? Theme.cardHover.cgColor : Theme.card.cgColor
        layer?.borderColor = keyboardFocused ? Theme.accent.cgColor
            : hovered ? Theme.borderHover.cgColor : Theme.border.cgColor
        layer?.borderWidth = keyboardFocused ? 2 : 1
    }
}

/// The ⌃⌥ number wrapped in an amber ring — "this session is connected
/// to an agent" (option A of design/agent-row-icons.html).
/// Borderless fields top-align their text and start at the very edge of the
/// frame. This cell insets the text 10pt and centers it vertically, for both
/// display and the field editor.
final class PaddedTextFieldCell: NSTextFieldCell {
    private func adjusted(_ rect: NSRect) -> NSRect {
        // The field editor can be installed before layout has given the field
        // a real frame. Insetting a degenerate rect hands AppKit a negative
        // width, and the text view it puts in the clip view then traps with
        // "Invalid view geometry: width is NaN". Pass such rects through.
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 20 else { return rect }
        var inset = rect.insetBy(dx: 10, dy: 0)
        let ideal = cellSize(forBounds: rect).height
        let delta = inset.height - ideal
        if delta > 0, delta.isFinite {
            inset.origin.y += delta / 2
            inset.size.height -= delta
        }
        return inset
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: adjusted(rect))
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView,
                       editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: adjusted(rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView,
                         editor textObj: NSText, delegate: Any?,
                         start selStart: Int, length selLength: Int) {
        super.select(withFrame: adjusted(rect), in: controlView,
                     editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}

final class RingNumberView: NSView {
    private let number: Int
    private let side: CGFloat
    init(number: Int, side: CGFloat = 16) {
        self.number = number
        self.side = side
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = min(bounds.width, bounds.height, self.side)
        let square = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side).insetBy(dx: 0.75, dy: 0.75)
        let ring = NSBezierPath(ovalIn: square)
        ring.lineWidth = 1.3
        Theme.accent.setStroke()
        ring.stroke()

        let text = NSAttributedString(
            string: "\(number)",
            attributes: [.font: NSFont.systemFont(
                            ofSize: max(8.5, side * 0.36), weight: .semibold),
                         .foregroundColor: Theme.accent])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2))
    }
}

/// List row hover: quiet by default, card tint under the pointer.
class HoverRowView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        setHovered(true)
    }
    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }
    func setHovered(_ hovered: Bool) {
        layer?.backgroundColor = hovered ? Theme.cardHover.cgColor : NSColor.clear.cgColor
    }
}

/// The VoiceFlow waveform mark — a dot, a wave, a dot. Marks the assistant,
/// which is not a session and never wears a number.
final class WaveformIconView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 12) }

    override func draw(_ dirtyRect: NSRect) {
        let color = Theme.text2
        color.setStroke()
        color.setFill()

        let midY = bounds.midY
        let dotR: CGFloat = 1.8
        NSBezierPath(ovalIn: NSRect(x: 0, y: midY - dotR, width: dotR * 2, height: dotR * 2)).fill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width - dotR * 2, y: midY - dotR, width: dotR * 2, height: dotR * 2)).fill()

        let wave = NSBezierPath()
        wave.lineWidth = 1.8
        wave.lineCapStyle = .round
        let x0 = dotR * 2 + 1.5
        let x1 = bounds.width - dotR * 2 - 1.5
        let w = x1 - x0
        wave.move(to: NSPoint(x: x0, y: midY))
        wave.curve(to: NSPoint(x: x0 + w / 2, y: midY),
                   controlPoint1: NSPoint(x: x0 + w * 0.2, y: midY + 5),
                   controlPoint2: NSPoint(x: x0 + w * 0.3, y: midY + 5))
        wave.curve(to: NSPoint(x: x1, y: midY),
                   controlPoint1: NSPoint(x: x0 + w * 0.7, y: midY - 5),
                   controlPoint2: NSPoint(x: x0 + w * 0.8, y: midY - 5))
        wave.stroke()
    }
}

/// A notice that never takes a click: the transient note strip sits over
/// the composer for a few seconds and must not swallow the tap meant for it.
final class PassThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
