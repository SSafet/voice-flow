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

struct AgentSessionRow {
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
    let archived: Bool
    /// Consumed thread kept as history (ticket #17) — tagged "completed".
    let completed: Bool
    /// Session died with the stack still active — tagged "ghost".
    let ghost: Bool
}

struct AgentJobRow {
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
    let dailyBudgetUSD: Double
    let spentTodayUSD: Double
    let maxDurationSeconds: TimeInterval
    let maxAttempts: Int
    let hasPendingTrigger: Bool
    let runs: [AgentRunRow]
}

struct AgentRunRow {
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
    let dailyBudgetUSD: Double
    let maxDurationSeconds: TimeInterval
    let maxAttempts: Int
    let enabled: Bool
}

struct AgentAutomationDefaults {
    let runtime: AgentRuntimeKind
    let modelID: String?
}

struct AgentAssistantRow {
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
    func agentSessionRows() -> [AgentSessionRow]
    func agentThread(for sessionId: String) -> [AppDelegate.SessionPush]
    func markThreadSeen(_ sessionId: String)
    /// True when this session has a blocked ask waiting for the user.
    func hasPendingAsk(for sessionId: String) -> Bool
    /// Route a typed message: resolves the pending ask if one waits,
    /// otherwise queues it in the session's inbox.
    func sendMessage(toSession sessionId: String, text: String)
    func speakThread(_ sessionId: String)
    /// User marked the thread done — delete its stack, session, overlays.
    func completeThread(_ sessionId: String)
    func agentAssistantRows() -> [AgentAssistantRow]
    func agentJobRows() -> [AgentJobRow]
    func agentAutomationModels() -> [OpenRouterModel]
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

    private enum Mode {
        case destination(AgentsDestination)
        case search
        case thread(String)
        case job(String)
        case automationCreate
        case automationEdit(String)
        case assistantWorkspace(String, AssistantWorkspaceTab)
        case assistantCreate
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
        let budget: String
        let duration: String
        let attempts: String
    }
    private enum AssistantWorkspaceTab: String, CaseIterable {
        case overview = "Overview"
        case conversations = "Conversations"
        case memory = "Memory & Skills"
        case settings = "Settings"
    }
    private var mode: Mode = .destination(.now)
    private var currentDestination: AgentsDestination = .now

    var openSessionId: String? {
        if case .thread(let id) = mode { return id }
        return nil
    }

    private var contentStack: NSView!          // flipped document view
    private var scrollView: NSScrollView!
    private var navigationBar: NSView!
    private var navigationButtons: [AgentsDestination: NSButton] = [:]
    private var searchButton: NSButton!
    private var searchField: NSTextField?
    private var searchQuery = ""
    private var automationSearchField: NSTextField?
    private var automationSearchQuery = ""
    private var automationFilter: AutomationFilter = .all
    private var composerField: NSTextField?
    private var automationNameField: NSTextField?
    private var automationInstructionsView: NSTextView?
    private var automationAssistantPopUp: NSPopUpButton?
    private var automationRuntimePopUp: NSPopUpButton?
    private var automationTriggerPopUp: NSPopUpButton?
    private var automationModelCombo: OpenRouterModelComboBox?
    private var automationIntervalField: NSTextField?
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
    private var assistantMemoryRevision: String?
    private var assistantSkillButtons: [String: NSButton] = [:]
    private var assistantDeleteConfirmationSlug: String?
    private var inlineError: String?
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
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.refreshHoverStatesForPointer()
        }

        navigationBar = buildNavigationBar()
        addSubview(navigationBar)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            navigationBar.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            navigationBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            navigationBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            navigationBar.heightAnchor.constraint(equalToConstant: 36),
            scrollView.topAnchor.constraint(equalTo: navigationBar.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    private func buildNavigationBar() -> NSView {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)

        for destination in AgentsDestination.allCases {
            let button = NSButton(
                title: destination.label, target: self,
                action: #selector(destinationTapped(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: 10.5, weight: .medium)
            button.identifier = NSUserInterfaceItemIdentifier(destination.rawValue)
            button.setAccessibilityLabel("Open \(destination.label)")
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            navigationButtons[destination] = button
            stack.addArrangedSubview(button)
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
        searchButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(searchButton)

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(line)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: line.topAnchor, constant: -2),
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

    func openThread(_ sessionId: String) {
        currentDestination = .threads
        mode = .thread(sessionId)
        dataSource?.markThreadSeen(sessionId)
        rebuild()
    }

    /// Re-render whatever is on screen from fresh data. An in-progress
    /// composer draft (and its focus) survives the rebuild — pushes from
    /// other sessions must never eat what the user is typing.
    func refresh() {
        if case .thread(let sid) = mode {
            // A session with zero pushes is still a valid, messageable
            // thread — fall back to the list only when the session is gone.
            let known = dataSource?.agentSessionRows().contains { $0.id == sid } ?? false
            if !known, dataSource?.agentThread(for: sid).isEmpty ?? true {
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
        let draft = composerField?.stringValue ?? ""
        let assistantDraft = (
            assistantNameField?.stringValue,
            assistantDescriptionField?.stringValue,
            assistantVoiceField?.stringValue,
            assistantInstructionsView?.string,
            assistantMemoryView?.string)
        let automationDraft: AutomationFormValues? = {
            switch mode {
            case .automationCreate, .automationEdit: return currentAutomationFormValues()
            default: return nil
            }
        }()
        let hadFocus = composerField.map { field in
            (field.window?.firstResponder as? NSText)?.delegate === field
        } ?? false
        rebuild()
        if let field = composerField {
            if !draft.isEmpty { field.stringValue = draft }
            if hadFocus { field.window?.makeFirstResponder(field) }
        }
        if let value = assistantDraft.0 { assistantNameField?.stringValue = value }
        if let value = assistantDraft.1 { assistantDescriptionField?.stringValue = value }
        if let value = assistantDraft.2 { assistantVoiceField?.stringValue = value }
        if let value = assistantDraft.3 { assistantInstructionsView?.string = value }
        if let value = assistantDraft.4 { assistantMemoryView?.string = value }
        if let automationDraft { restoreAutomationForm(automationDraft) }
    }

    private func buildJob(_ jobId: String) {
        guard let dataSource,
              let job = dataSource.agentJobRows().first(where: { $0.id == jobId }) else {
            mode = .destination(.automations)
            buildAutomations()
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

        var metaText = "\(job.trigger.rawValue) · \(job.runtime.label)"
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
            place(row, below: &top, gap: 0)
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
        contentStack.subviews.forEach { $0.removeFromSuperview() }
        composerField = nil
        automationSearchField = nil
        automationNameField = nil
        automationInstructionsView = nil
        automationAssistantPopUp = nil
        automationRuntimePopUp = nil
        automationTriggerPopUp = nil
        automationModelCombo = nil
        automationIntervalField = nil
        automationBudgetField = nil
        automationDurationField = nil
        automationAttemptsField = nil
        assistantNameField = nil
        assistantDescriptionField = nil
        assistantVoiceField = nil
        assistantInstructionsView = nil
        assistantMemoryView = nil
        assistantSkillButtons = [:]
        switch mode {
        case .destination(let destination): buildDestination(destination)
        case .search: buildSearch()
        case .thread(let sid): buildThread(sid)
        case .job(let id): buildJob(id)
        case .automationCreate: buildAutomationForm(jobID: nil)
        case .automationEdit(let id): buildAutomationForm(jobID: id)
        case .assistantWorkspace(let slug, let tab): buildAssistantWorkspace(slug: slug, tab: tab)
        case .assistantCreate: buildAssistantCreate()
        }
        styleNavigation()
        let preferredHeight: CGFloat
        if case .destination(.now) = mode {
            let snapshot = nowSnapshot()
            let rows = snapshot.needsYou.count + snapshot.running.count
            let sections = (snapshot.needsYou.isEmpty ? 0 : 1) + (snapshot.running.isEmpty ? 0 : 1)
            preferredHeight = rows == 0 ? 126 : min(420, 64 + CGFloat(rows * 48 + sections * 28))
        } else {
            preferredHeight = 420
        }
        DispatchQueue.main.async { [weak self] in
            self?.onPreferredHeightChanged?(preferredHeight)
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
        case .assistants: buildAssistants()
        case .automations: buildAutomations()
        case .threads: buildThreads()
        }
    }

    private func styleNavigation() {
        let threads = dataSource?.agentSessionRows() ?? []
        let unreadThreads = threads.filter { $0.unread && !$0.archived }.count
        let attention = nowSnapshot().attentionCount
        for destination in AgentsDestination.allCases {
            guard let button = navigationButtons[destination] else { continue }
            let count: Int
            switch destination {
            case .now: count = attention
            case .threads: count = unreadThreads
            case .assistants, .automations: count = 0
            }
            let title = count > 0 ? "\(destination.label)  \(count)" : destination.label
            let selected = destination == currentDestination
            let attributed = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: selected ? .semibold : .medium),
                .foregroundColor: selected ? Theme.text : Theme.text3,
            ])
            if selected {
                attributed.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: Theme.accent,
                ], range: NSRange(location: 0, length: title.count))
            } else if count > 0 {
                attributed.addAttribute(
                    .foregroundColor, value: Theme.accent,
                    range: NSRange(location: destination.label.count + 2,
                                   length: title.count - destination.label.count - 2))
            }
            button.attributedTitle = attributed
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
                archived: row.archived)
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
        if snapshot.needsYou.isEmpty && snapshot.running.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "All clear\nNothing needs you and no agent is running.")
            empty.font = .systemFont(ofSize: 12.5, weight: .medium)
            empty.textColor = Theme.text2
            empty.alignment = .center
            place(empty, below: &top, gap: 34)
        } else {
            if !snapshot.needsYou.isEmpty {
                place(sectionHeader("NEEDS YOU", count: snapshot.needsYou.count), below: &top, gap: 8)
                for item in snapshot.needsYou { place(makeNowRow(item), below: &top, gap: 0) }
            }
            if !snapshot.running.isEmpty {
                place(sectionHeader("RUNNING NOW", count: snapshot.running.count), below: &top, gap: 14)
                for item in snapshot.running { place(makeNowRow(item), below: &top, gap: 0) }
            }
        }
        finishContent(top)
    }

    private func buildAssistants() {
        var top = contentStack.topAnchor
        let rows = dataSource?.agentAssistantRows() ?? []
        let create = makeRow(
            leading: symbolIcon("plus", description: "new assistant"),
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
                leading: WaveformIconView(), name: assistant.name,
                unread: assistant.attentionCount > 0,
                preview: assistant.description.isEmpty ? inventory : "\(assistant.description) · \(inventory)",
                time: state)
            view.rowAction = .assistantWorkspace(assistant.slug)
            place(view, below: &top, gap: 0)
        }
        if rows.isEmpty { place(emptyLabel("No assistants available"), below: &top, gap: 28) }
        finishContent(top)
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

        if let inlineError { place(errorLabel(inlineError), below: &top, gap: 10) }
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
        if let inlineError { place(errorLabel(inlineError), below: &top, gap: 8) }

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
            place(row, below: &top, gap: 0)
        }
        for job in attentionJobs.prefix(2) {
            let title = job.prompt.components(separatedBy: .newlines).first ?? "Automation"
            let row = makeRow(
                leading: jobStateIcon(job.state), name: title,
                unread: true, preview: job.state.rawValue, time: "")
            row.rowAction = .job(job.id)
            place(row, below: &top, gap: 0)
        }
        if runningConversation == nil && attentionJobs.isEmpty {
            place(emptyLabel("Nothing active"), below: &top, gap: 12)
        }

        let recent = snapshot.conversations.filter { !$0.messages.isEmpty }.prefix(3)
        place(sectionHeader("CONTINUE", count: snapshot.conversations.filter { !$0.messages.isEmpty }.count),
              below: &top, gap: 18)
        for conversation in recent {
            let row = makeAssistantConversationRow(conversation)
            place(row, below: &top, gap: 0)
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
        }
    }

    private func buildAssistantSettings(_ snapshot: AssistantWorkspaceSnapshot,
                                        top: inout NSLayoutYAxisAnchor) {
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

        let save = NSButton(title: "Save settings", target: self,
                            action: #selector(saveAssistantSettingsTapped))
        save.identifier = NSUserInterfaceItemIdentifier(snapshot.document.revision)
        save.bezelStyle = .rounded
        save.controlSize = .small
        place(save, below: &top, gap: 12)

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

    private func formField(placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.textColor = Theme.text
        field.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10)
        field.isBezeled = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 7
        field.heightAnchor.constraint(equalToConstant: 30).isActive = true
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
        let name = assistantNameField?.stringValue
        let description = assistantDescriptionField?.stringValue
        let voice = assistantVoiceField?.stringValue
        let instructions = assistantInstructionsView?.string
        let memory = assistantMemoryView?.string
        let skillStates = assistantSkillButtons.mapValues(\.state)
        rebuild()
        if let name { assistantNameField?.stringValue = name }
        if let description { assistantDescriptionField?.stringValue = description }
        if let voice { assistantVoiceField?.stringValue = voice }
        if let instructions { assistantInstructionsView?.string = instructions }
        if let memory { assistantMemoryView?.string = memory }
        for (name, state) in skillStates { assistantSkillButtons[name]?.state = state }
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
            budget: automationBudgetField?.stringValue ?? "",
            duration: automationDurationField?.stringValue ?? "",
            attempts: automationAttemptsField?.stringValue ?? "")
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
        if runtime == .opencode && model == nil {
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
            runtime: runtime, modelID: runtime == .opencode ? model : nil,
            trigger: trigger, prompt: prompt,
            intervalSeconds: trigger == .interval ? intervalMinutes * 60 : nil,
            dailyBudgetUSD: budget,
            maxDurationSeconds: durationMinutes * 60,
            maxAttempts: attempts, enabled: enabled)
    }

    private func rebuildPreservingAutomationForm(_ values: AutomationFormValues) {
        rebuild()
        restoreAutomationForm(values)
    }

    private func restoreAutomationForm(_ values: AutomationFormValues) {
        automationNameField?.stringValue = values.name
        automationInstructionsView?.string = values.instructions
        select(popUp: automationAssistantPopUp, representedObject: values.assistantSlug)
        select(popUp: automationRuntimePopUp, representedObject: values.runtime)
        select(popUp: automationTriggerPopUp, representedObject: values.trigger)
        automationModelCombo?.stringValue = values.model
        automationIntervalField?.stringValue = values.interval
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

    private func buildAutomations() {
        var top = contentStack.topAnchor
        let tools = NSView()
        let search = formField(placeholder: "Search automations")
        search.stringValue = automationSearchQuery
        search.delegate = self
        search.setAccessibilityLabel("Search automations")
        automationSearchField = search
        let create = NSButton(title: "+ New", target: self,
                              action: #selector(newAutomationTapped))
        create.bezelStyle = .rounded
        create.controlSize = .small
        create.setAccessibilityLabel("New automation")
        for view in [search, create] {
            view.translatesAutoresizingMaskIntoConstraints = false
            tools.addSubview(view)
        }
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: tools.leadingAnchor),
            search.topAnchor.constraint(equalTo: tools.topAnchor),
            search.bottomAnchor.constraint(equalTo: tools.bottomAnchor),
            create.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 8),
            create.trailingAnchor.constraint(equalTo: tools.trailingAnchor),
            create.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            create.widthAnchor.constraint(equalToConstant: 58),
        ])
        place(tools, below: &top, gap: 6)

        let filter = NSSegmentedControl(
            labels: AutomationFilter.allCases.map(\.label),
            trackingMode: .selectOne, target: self,
            action: #selector(automationFilterChanged(_:)))
        filter.selectedSegment = automationFilter.rawValue
        filter.segmentStyle = .texturedRounded
        filter.controlSize = .small
        filter.setAccessibilityLabel("Filter automations")
        place(filter, below: &top, gap: 8)

        let allJobs = dataSource?.agentJobRows() ?? []
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
                let view = makeRow(
                    leading: job.isEnabled
                        ? jobStateIcon(job.state)
                        : symbolIcon("pause.circle", description: "automation disabled"),
                    name: job.name,
                    unread: job.state == .blocked || job.state == .failed,
                    preview: "\(job.assistantName) · \(job.preview)", time: job.time)
                view.rowAction = .job(job.id)
                place(view, below: &top, gap: 0)
            }
        }
        if jobs.isEmpty {
            let message = allJobs.isEmpty
                ? "No automations yet" : "No automations match this view"
            place(emptyLabel(message), below: &top, gap: 30)
        }
        finishContent(top)
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
            buildAutomations()
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
        interval.stringValue = String(format: "%.0f", (existing?.intervalSeconds ?? 3_600) / 60)
        interval.setAccessibilityLabel("Automation interval in minutes")
        automationIntervalField = interval
        place(automationFormRow([
            ("TRIGGER", trigger), ("EVERY (MIN)", interval),
        ]), below: &top, gap: 12)

        place(formLabel("OPENCODE MODEL"), below: &top, gap: 12)
        let model = OpenRouterModelComboBox()
        model.configure(
            models: dataSource.agentAutomationModels(),
            selectedID: existing?.modelID ?? defaults.modelID ?? "")
        model.setAccessibilityLabel("OpenRouter model")
        model.heightAnchor.constraint(equalToConstant: 30).isActive = true
        automationModelCombo = model
        place(model, below: &top, gap: 5)

        let budget = formField(placeholder: "1.00")
        budget.stringValue = String(format: "%.2f", existing?.dailyBudgetUSD ?? 1)
        budget.setAccessibilityLabel("Daily budget in dollars")
        automationBudgetField = budget
        let duration = formField(placeholder: "15")
        duration.stringValue = String(format: "%.0f", (existing?.maxDurationSeconds ?? 900) / 60)
        duration.setAccessibilityLabel("Maximum runtime in minutes")
        automationDurationField = duration
        let attempts = formField(placeholder: "3")
        attempts.stringValue = String(existing?.maxAttempts ?? 3)
        attempts.setAccessibilityLabel("Maximum attempts")
        automationAttemptsField = attempts
        place(automationFormRow([
            ("BUDGET / DAY", budget), ("MAX MIN", duration), ("ATTEMPTS", attempts),
        ]), below: &top, gap: 12)

        if let inlineError { place(errorLabel(inlineError), below: &top, gap: 10) }
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
            control.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            column.addArrangedSubview(control)
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
        case .inbox: return "Inbox message"
        case .capture: return "Capture completed"
        case .watcher: return "Watcher action"
        }
    }

    private func updateAutomationFormAvailability() {
        let runtime = automationRuntimePopUp?.selectedItem?.representedObject as? String
        automationModelCombo?.isEnabled = runtime == AgentRuntimeKind.opencode.rawValue
        let trigger = automationTriggerPopUp?.selectedItem?.representedObject as? String
        automationIntervalField?.isEnabled = trigger == AgentJobTriggerKind.interval.rawValue
    }

    private func buildThreads() {
        var top = contentStack.topAnchor
        let create = makeRow(
            leading: symbolIcon("plus", description: "new conversation"),
            name: "New conversation", unread: false,
            preview: "Start a separate Assistant conversation", time: "")
        create.rowAction = .newAssistant
        place(create, below: &top, gap: 2)

        let rows = dataSource?.agentSessionRows() ?? []
        let grouped = AgentsThreadProjection.grouped(threadProjectionInputs())
        for group in AgentsThreadGroup.allCases {
            let ids = Set((grouped[group] ?? []).map(\.id))
            let members = rows.filter { row in
                ids.contains(AgentsThreadID(
                    source: row.kind == .assistant ? .assistant : .mcp,
                    value: row.id))
            }
            guard !members.isEmpty else { continue }
            place(sectionHeader(group.label.uppercased(), count: members.count), below: &top, gap: 12)
            for row in members {
                let view = makeRow(
                    leading: leadingIcon(for: row), name: row.name,
                    unread: row.unread || row.pendingAsk,
                    preview: "\(row.owner) · \(row.preview)", time: row.time)
                view.rowAction = row.kind == .assistant ? .assistant(row.id) : .mcp(row.id)
                place(view, below: &top, gap: 0)
            }
        }
        finishContent(top)
    }

    private func makeNowRow(_ item: AgentsNowItem) -> AgentListRowView {
        let leading: NSView
        switch item.objectID {
        case .thread(let id):
            if let row = dataSource?.agentSessionRows().first(where: { $0.id == id.value }) {
                leading = leadingIcon(for: row)
            } else {
                leading = symbolIcon("text.bubble", description: "thread")
            }
        case .automation(let id):
            let state = dataSource?.agentJobRows().first(where: { $0.id == id })?.state ?? .failed
            leading = jobStateIcon(state)
        case .assistant:
            leading = WaveformIconView()
        }
        let view = makeRow(
            leading: leading, name: item.title, unread: item.needsAttention,
            preview: "\(item.owner) · \(item.summary)", time: "")
        view.rowAction = .object(item.objectID)
        return view
    }

    private func sectionHeader(_ title: String, count: Int?) -> NSView {
        let value = count.map { "\(title)  \($0)" } ?? title
        let text = NSTextField(labelWithString: value)
        text.font = .systemFont(ofSize: 10.5, weight: .semibold)
        text.textColor = Theme.text3
        text.setAccessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        return text
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
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Theme.text
        field.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10)
        field.isBezeled = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.delegate = self
        field.setAccessibilityLabel("Search assistants, automations, and threads")
        field.heightAnchor.constraint(equalToConstant: 30).isActive = true
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
                    place(row, below: &top, gap: 0)
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
            documents.append(AgentsSearchDocument(
                objectID: .thread(AgentsThreadID(
                    source: row.kind == .assistant ? .assistant : .mcp,
                    value: row.id)),
                primaryText: row.name, secondaryText: row.owner,
                indexText: row.preview, updatedAt: row.updatedAt))
        }
        return documents
    }

    /// The leading slot carries the session's state (design/agent-row-icons
    /// option A): connected = ⌃⌥ number in an amber ring, ghost = bare
    /// muted number, completed = quiet outlined check. No text suffixes.
    private func leadingIcon(for row: AgentSessionRow) -> NSView {
        if row.kind == .assistant {
            if let number = row.number { return RingNumberView(number: number) }
            return WaveformIconView()
        }
        guard let number = row.number else {
            let image = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle",
                                                   accessibilityDescription: "completed") ?? NSImage())
            image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            image.contentTintColor = Theme.text3
            return image
        }
        if row.ghost {
            let label = NSTextField(labelWithString: "\(number)")
            label.font = .systemFont(ofSize: 10.5, weight: .semibold)
            label.textColor = Theme.text3
            return label
        }
        return RingNumberView(number: number)
    }

    private func makeRow(leading: NSView, name: String, unread: Bool,
                         preview: String, time: String) -> AgentListRowView {
        let row = AgentListRowView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12.5, weight: unread ? .semibold : .regular)
        nameLabel.textColor = unread ? Theme.text : Theme.text2
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        // Long titles/previews must truncate, never stretch the panel.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let previewLabel = NSTextField(labelWithString: preview)
        previewLabel.font = .systemFont(ofSize: 10.5)
        previewLabel.textColor = Theme.text3
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = Theme.text3
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [leading, nameLabel, previewLabel, timeLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            leading.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 9),
            leading.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leading.widthAnchor.constraint(equalToConstant: 18),

            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 34),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),

            previewLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            previewLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -8),
            previewLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -7),

            timeLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -9),
            timeLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        row.addGestureRecognizer(click)
        return row
    }

    @objc private func rowClicked(_ gesture: NSClickGestureRecognizer) {
        guard let row = gesture.view as? AgentListRowView,
              let action = row.rowAction else { return }
        switch action {
        case .newAssistantIdentity:
            currentDestination = .assistants
            mode = .assistantCreate
            inlineError = nil
            rebuild()
        case .newAssistant:
            onNewAssistant?()
        case .newAssistantConversation(let slug):
            do {
                let id = try dataSource?.createAgentAssistantConversation(slug: slug)
                inlineError = nil
                if let id { onOpenAssistantSession?(id) }
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
            onOpenAssistantSession?(id)
        case .mcp(let id):
            onOpenSession?(id)
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
        case .object(let objectID):
            open(objectID)
        }
    }

    private func open(_ objectID: AgentsObjectID) {
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
            if id.source == .assistant {
                onOpenAssistantSession?(id.value)
            } else {
                onOpenSession?(id.value)
                openThread(id.value)
            }
        }
    }

    private func symbolIcon(_ name: String, description: String) -> NSView {
        let image = NSImageView(image: NSImage(
            systemSymbolName: name, accessibilityDescription: description) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
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
        let view = symbolIcon(symbol, description: "automation \(state.rawValue)")
        (view as? NSImageView)?.contentTintColor = state == .blocked || state == .failed
            ? Theme.accent : Theme.text3
        return view
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

    private func buildThread(_ sessionId: String) {
        guard let dataSource else { return }
        let pushes = dataSource.agentThread(for: sessionId)
        let rows = dataSource.agentSessionRows()
        let title = rows.first { $0.id == sessionId }?.name ?? "Claude"
        let pendingAsk = dataSource.hasPendingAsk(for: sessionId)

        var top = contentStack.topAnchor

        // Nav bar: ‹ back — centered title — 🔊, hairline below.
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let back = NSButton(title: "‹", target: self, action: #selector(backTapped))
        back.isBordered = false
        back.font = .systemFont(ofSize: 16, weight: .medium)
        back.contentTintColor = Theme.text2

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.alignment = .center

        let speak = NSButton(image: NSImage(systemSymbolName: "speaker.wave.2",
                                            accessibilityDescription: nil) ?? NSImage(),
                             target: self, action: #selector(speakTapped))
        speak.isBordered = false
        speak.contentTintColor = Theme.text3
        speak.identifier = NSUserInterfaceItemIdentifier(sessionId)

        // ✓ — mark the thread complete: history is kept until the user
        // says it's done, then it goes away entirely (ticket QA).
        let complete = NSButton(image: NSImage(systemSymbolName: "checkmark.circle",
                                               accessibilityDescription: nil) ?? NSImage(),
                                target: self, action: #selector(completeTapped))
        complete.isBordered = false
        complete.contentTintColor = Theme.text3
        complete.toolTip = "Mark complete — remove this thread"
        complete.identifier = NSUserInterfaceItemIdentifier(sessionId)

        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor

        for v in [back, titleLabel, complete, speak, line] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            titleLabel.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: back.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: complete.leadingAnchor, constant: -8),
            complete.trailingAnchor.constraint(equalTo: speak.leadingAnchor, constant: -8),
            complete.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            speak.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -4),
            speak.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            header.heightAnchor.constraint(equalToConstant: 34),
        ])
        place(header, below: &top, gap: 0)

        // Flat blocks — one per push, question or not.
        var attachedComposer = false
        for (index, push) in pushes.enumerated() {
            let block = NSView()
            block.translatesAutoresizingMaskIntoConstraints = false

            let text = NSTextField(wrappingLabelWithString: push.text)
            text.font = .systemFont(ofSize: 12.5)
            text.textColor = push.isAsk ? Theme.text : Theme.text2
            text.maximumNumberOfLines = 0
            text.isSelectable = true
            text.translatesAutoresizingMaskIntoConstraints = false
            block.addSubview(text)

            var lastAnchor = text.bottomAnchor
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: block.topAnchor, constant: 9),
                text.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 4),
                text.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -4),
            ])

            if let answer = push.answer {
                // The user's reply lives attached to what it answered.
                let arrow = NSTextField(labelWithString: "↳")
                arrow.font = .systemFont(ofSize: 11.5, weight: .bold)
                arrow.textColor = Theme.accent
                let answerLabel = NSTextField(wrappingLabelWithString: answer)
                answerLabel.font = .systemFont(ofSize: 11.5)
                answerLabel.textColor = Theme.text2
                answerLabel.maximumNumberOfLines = 0
                for v in [arrow, answerLabel] {
                    v.translatesAutoresizingMaskIntoConstraints = false
                    block.addSubview(v)
                }
                NSLayoutConstraint.activate([
                    arrow.topAnchor.constraint(equalTo: lastAnchor, constant: 6),
                    arrow.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 16),
                    answerLabel.topAnchor.constraint(equalTo: arrow.topAnchor),
                    answerLabel.leadingAnchor.constraint(equalTo: arrow.trailingAnchor, constant: 7),
                    answerLabel.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -4),
                ])
                lastAnchor = answerLabel.bottomAnchor
            } else if push.isAsk, pendingAsk, index == pushes.lastIndex(where: { $0.isAsk && $0.answer == nil }) {
                // The attached composer IS the ask signal.
                let (row, field) = makeComposer(placeholder: "answer…", sessionId: sessionId)
                row.translatesAutoresizingMaskIntoConstraints = false
                block.addSubview(row)
                NSLayoutConstraint.activate([
                    row.topAnchor.constraint(equalTo: lastAnchor, constant: 10),
                    row.leadingAnchor.constraint(equalTo: block.leadingAnchor, constant: 4),
                    row.trailingAnchor.constraint(equalTo: block.trailingAnchor, constant: -4),
                ])
                lastAnchor = row.bottomAnchor
                composerField = field
                attachedComposer = true
            }

            lastAnchor.constraint(equalTo: block.bottomAnchor, constant: -9).isActive = true

            if index < pushes.count - 1 {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = Theme.border.cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                block.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: block.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: block.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: block.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
            place(block, below: &top, gap: 0)
        }

        if !attachedComposer {
            let (row, field) = makeComposer(placeholder: "message this session…", sessionId: sessionId)
            place(row, below: &top, gap: 10)
            composerField = field
        }

        let bottom = top.constraint(equalTo: contentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    private func makeComposer(placeholder: String, sessionId: String) -> (NSView, NSTextField) {
        let row = NSView()

        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12.5)
        field.textColor = Theme.text
        field.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10)
        field.isBezeled = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.identifier = NSUserInterfaceItemIdentifier(sessionId)
        field.target = self
        field.action = #selector(composerSent(_:))
        field.lineBreakMode = .byWordWrapping
        field.cell?.usesSingleLineMode = false
        // Multiline cells swallow Return instead of firing the action —
        // the delegate turns Return back into SEND (Option+Return = newline).
        field.delegate = self

        let send = NSButton(image: NSImage(systemSymbolName: "arrow.up.circle.fill",
                                           accessibilityDescription: nil) ?? NSImage(),
                            target: self, action: #selector(sendTapped(_:)))
        send.isBordered = false
        send.contentTintColor = Theme.accent
        send.identifier = NSUserInterfaceItemIdentifier(sessionId)

        for v in [field, send] {
            v.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: row.topAnchor),
            field.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
            send.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            send.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            send.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
        return (row, field)
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
        rebuild()
    }

    @objc private func newAutomationTapped() {
        currentDestination = .automations
        mode = .automationCreate
        inlineError = nil
        automationDeleteConfirmationID = nil
        rebuild()
    }

    @objc private func automationFilterChanged(_ sender: NSSegmentedControl) {
        automationFilter = AutomationFilter(rawValue: sender.selectedSegment) ?? .all
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
                mode = .job(id)
            } else {
                let id = try dataSource.createAgentAutomation(draft)
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
        mode = .destination(currentDestination)
        inlineError = nil
        assistantDeleteConfirmationSlug = nil
        automationDeleteConfirmationID = nil
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
            inlineError = nil
            mode = .assistantWorkspace(slug, .overview)
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuildPreservingAssistantDraft()
        }
    }

    @objc private func saveAssistantSettingsTapped(_ sender: NSButton) {
        guard let dataSource,
              case .assistantWorkspace(let slug, _) = mode,
              let revision = sender.identifier?.rawValue,
              let snapshot = try? dataSource.assistantWorkspace(slug: slug) else { return }
        let draft = AssistantDraft(
            name: assistantNameField?.stringValue ?? snapshot.document.definition.name,
            description: assistantDescriptionField?.stringValue ?? snapshot.document.definition.description,
            voice: assistantVoiceField?.stringValue,
            instructions: assistantInstructionsView?.string ?? snapshot.document.definition.instructions,
            selectedSkills: snapshot.document.definition.selectedSkills)
        do {
            try dataSource.updateAgentAssistant(
                slug: slug, draft: draft, expectedRevision: revision)
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
            inlineError = nil
            rebuild()
        } catch {
            inlineError = error.localizedDescription
            rebuildPreservingAssistantDraft()
        }
    }

    @objc private func saveAssistantSkillsTapped() {
        guard let dataSource,
              case .assistantWorkspace(let slug, _) = mode,
              let snapshot = try? dataSource.assistantWorkspace(slug: slug) else { return }
        let selected = assistantSkillButtons
            .filter { $0.value.state == .on }
            .map(\.key).sorted()
        let definition = snapshot.document.definition
        let draft = AssistantDraft(
            name: definition.name, description: definition.description,
            voice: definition.voice, instructions: definition.instructions,
            selectedSkills: selected)
        do {
            try dataSource.updateAgentAssistant(
                slug: slug, draft: draft,
                expectedRevision: snapshot.document.revision)
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
        guard let id = sender.identifier?.rawValue else { return }
        dataSource?.speakThread(id)
    }

    @objc private func completeTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        dataSource?.completeThread(id)
        currentDestination = .threads
        mode = .destination(.threads)
        rebuild()
    }

    @objc private func composerSent(_ sender: NSTextField) { submit(sender) }

    /// Return sends; Option+Return inserts a newline.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let field = control as? NSTextField else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        submit(field)
        return true
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

    @objc private func sendTapped(_ sender: NSButton) {
        if let field = composerField { submit(field) }
    }

    private func submit(_ field: NSTextField) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = field.identifier?.rawValue else { return }
        field.stringValue = ""
        dataSource?.sendMessage(toSession: id, text: text)
        // The answer attaches to its ask (or queues) — re-render to show it.
        DispatchQueue.main.async { self.refresh() }
    }
}

private enum AgentListRowAction {
    case newAssistantIdentity
    case newAssistant
    case newAssistantConversation(String)
    case newJob
    case assistant(String)
    case mcp(String)
    case job(String)
    case assistantWorkspace(String)
    case object(AgentsObjectID)
}

private final class AgentListRowView: HoverRowView {
    var rowAction: AgentListRowAction?
}

/// The ⌃⌥ number wrapped in an amber ring — "this session is connected
/// to an agent" (option A of design/agent-row-icons.html).
final class RingNumberView: NSView {
    private let number: Int
    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = min(bounds.width, bounds.height, 16)
        let square = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                            width: side, height: side).insetBy(dx: 0.75, dy: 0.75)
        let ring = NSBezierPath(ovalIn: square)
        ring.lineWidth = 1.3
        Theme.accent.setStroke()
        ring.stroke()

        let text = NSAttributedString(
            string: "\(number)",
            attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .semibold),
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
