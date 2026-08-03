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
    let state: AgentJobState
    let runtime: AgentRuntimeKind
    let trigger: AgentJobTriggerKind
    let modelID: String?
    let prompt: String
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
}

final class AgentsView: NSView, NSTextFieldDelegate {
    weak var dataSource: AgentsDataSource?
    /// Local Assistant sessions share this list but keep their native chat
    /// lifecycle instead of being forced through MCP push semantics.
    var onNewAssistant: (() -> Void)?
    var onNewAgentJob: (() -> Void)?
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
        case assistantWorkspace(String, AssistantWorkspaceTab)
        case assistantCreate
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
    private var composerField: NSTextField?
    private var assistantNameField: NSTextField?
    private var assistantDescriptionField: NSTextField?
    private var assistantVoiceField: NSTextField?
    private var assistantInstructionsView: NSTextView?
    private var assistantMemoryView: NSTextView?
    private var assistantMemoryKind = "core"
    private var assistantMemoryRevision: String?
    private var assistantSkillButtons: [String: NSButton] = [:]
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
        let back = NSButton(title: "‹", target: self, action: #selector(backTapped))
        back.isBordered = false
        back.font = .systemFont(ofSize: 16, weight: .medium)
        back.contentTintColor = Theme.text2
        back.setAccessibilityLabel("Back to agents")
        let title = NSTextField(labelWithString: job.name)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = Theme.text
        title.lineBreakMode = .byTruncatingTail
        title.alignment = .center
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Theme.border.cgColor
        for view in [back, title, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 2),
            back.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -4),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: back.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -28),
            line.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            header.heightAnchor.constraint(equalToConstant: 34),
        ])
        place(header, below: &top, gap: 0)

        var metaText = "\(job.state.rawValue)  ·  \(job.runtime.label)  ·  \(job.trigger.rawValue)"
        if let modelID = job.modelID { metaText += "  ·  \(modelID)" }
        let meta = NSTextField(labelWithString: metaText)
        meta.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        meta.textColor = job.state == .blocked || job.state == .failed ? Theme.accent : Theme.text3
        meta.setAccessibilityLabel(
            "Automation state \(job.state.rawValue), runtime \(job.runtime.label), trigger \(job.trigger.rawValue)"
                + (job.modelID.map { ", model \($0)" } ?? ""))
        place(meta, below: &top, gap: 14)

        let prompt = NSTextField(wrappingLabelWithString: job.prompt)
        prompt.font = .systemFont(ofSize: 12.5)
        prompt.textColor = Theme.text2
        prompt.maximumNumberOfLines = 0
        prompt.isSelectable = true
        place(prompt, below: &top, gap: 10)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.distribution = .fillEqually
        let run = NSButton(title: "Run now", target: self, action: #selector(runJobTapped(_:)))
        run.identifier = NSUserInterfaceItemIdentifier(job.id)
        run.isEnabled = job.state != .running
        run.setAccessibilityLabel("Run automation now")
        let secondary: NSButton
        if job.state == .running {
            secondary = NSButton(title: "Cancel", target: self, action: #selector(cancelJobTapped(_:)))
            secondary.setAccessibilityLabel("Cancel running automation")
        } else {
            let enable = job.state == .disabled || job.state == .cancelled
            secondary = NSButton(
                title: enable ? "Enable" : "Disable",
                target: self, action: #selector(toggleJobTapped(_:)))
            secondary.tag = enable ? 1 : 0
            secondary.setAccessibilityLabel(enable ? "Enable automation" : "Disable automation")
        }
        secondary.identifier = NSUserInterfaceItemIdentifier(job.id)
        for button in [run, secondary] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            actions.addArrangedSubview(button)
        }
        place(actions, below: &top, gap: 18)

        let bottom = top.constraint(equalTo: contentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    // ── Rendering ───────────────────────────────────────

    private func rebuild() {
        contentStack.subviews.forEach { $0.removeFromSuperview() }
        composerField = nil
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
                updatedAt: row.updatedAt, state: state)
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

    private func buildAutomations() {
        var top = contentStack.topAnchor
        let create = makeRow(
            leading: symbolIcon("plus", description: "new automation"),
            name: "New automation", unread: false,
            preview: "Run an assistant manually, on a schedule, or from an event", time: "")
        create.rowAction = .newJob
        place(create, below: &top, gap: 2)

        let jobs = dataSource?.agentJobRows() ?? []
        let grouped = AgentsAutomationProjection.grouped(automationProjectionInputs())
        for group in AgentsAutomationGroup.allCases {
            let ids = Set((grouped[group] ?? []).map(\.id))
            let members = jobs.filter { ids.contains($0.id) }
            guard !members.isEmpty else { continue }
            place(sectionHeader(group.label.uppercased(), count: members.count), below: &top, gap: 12)
            for job in members {
                let view = makeRow(
                    leading: jobStateIcon(job.state), name: job.name,
                    unread: job.state == .blocked || job.state == .failed,
                    preview: "\(job.assistantName) · \(job.preview)", time: job.time)
                view.rowAction = .job(job.id)
                place(view, below: &top, gap: 0)
            }
        }
        finishContent(top)
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

    private func sectionHeader(_ title: String, count: Int) -> NSView {
        let text = NSTextField(labelWithString: "\(title)  \(count)")
        text.font = .systemFont(ofSize: 10.5, weight: .semibold)
        text.textColor = Theme.text3
        text.setAccessibilityLabel("\(title), \(count)")
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
            onNewAgentJob?()
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
        rebuild()
    }

    @objc private func searchTapped() {
        mode = .search
        rebuild()
    }

    @objc private func backTapped() {
        mode = .destination(currentDestination)
        inlineError = nil
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
        guard let field = obj.object as? NSTextField, field === searchField else { return }
        let value = field.stringValue
        guard value != searchQuery else { return }
        searchQuery = value
        DispatchQueue.main.async { [weak self] in
            guard let self, case .search = self.mode else { return }
            self.rebuild()
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
