import Cocoa

class WorkspaceEditorDataSource: AgentsDataSource {
    var sessions: [AgentSessionRow] = []
    var threadDetail: AgentThreadDetail?
    var sentMessages: [(AgentsThreadID, String, [String])] = []
    var documentVersion = 1
    var coreVersion = 1
    var ledgerVersion = 1
    var assistant = AssistantDraft(name: "FLORA", description: "Fixture", instructions: "Saved instructions")
    var core = "Saved core"
    var ledger = "Saved ledger"
    var systemModel = "saved-model"
    var systemInstructions = "Saved system instructions"
    var lastMemoryRevision: String?
    var lastSettingsRevision: String?
    var createdAutomations = 0
    var createdAssistants = 0
    var jobs: [AgentJobRow] = []
    var sourceOptions: [SourceSelectionOption] = []
    var afterAssistantUpdate: (() -> Void)?

    func agentDataSourceOptions() -> [SourceSelectionOption] { sourceOptions }

    func agentSessionRows() -> [AgentSessionRow] { sessions }
    func agentThreadDetail(for id: AgentsThreadID) -> AgentThreadDetail? { threadDetail?.id == id ? threadDetail : nil }
    func activateThread(_ id: AgentsThreadID) -> Bool { true }
    func markThreadSeen(_ id: AgentsThreadID) {}
    func sendMessage(toThread id: AgentsThreadID, text: String, attachments: [String]) throws { sentMessages.append((id, text, attachments)) }
    func speakThread(_ id: AgentsThreadID) {}
    func completeThread(_ id: AgentsThreadID) throws {}
    func reopenThread(_ id: AgentsThreadID) throws {}
    func deleteThread(_ id: AgentsThreadID) throws {}
    func agentAssistantRows() -> [AgentAssistantRow] {
        [AgentAssistantRow(slug: "flora", name: assistant.name, description: assistant.description,
                           isDefault: true, conversationCount: 0, automationCount: 0, skillCount: 1,
                           attentionCount: 0, running: false, updatedAt: nil)]
    }
    func agentSystemAgentRows() -> [AgentSystemAgentRow] {
        [AgentSystemAgentRow(kind: "speech_cleanup", name: "Speech cleanup", purpose: "Fixture",
                            trigger: "Dictation", runsOn: "Local", model: systemModel, defaultModel: "default-model",
                            effort: "low", effortLabel: "Low", supportsEffort: true,
                            instructions: systemInstructions, editableInstructions: true,
                            instructionsNote: nil, instructionsContract: nil, usesDefaults: false)]
    }
    func updateAgentSystemAgent(kind: String, model: String, effort: String?, instructions: String?) throws {
        systemModel = model
        if let instructions { systemInstructions = instructions }
    }
    func resetAgentSystemAgent(kind: String) throws { systemModel = "default-model"; systemInstructions = "Default instructions" }
    func testAgentSystemAgent(kind: String, completion: @escaping (String) -> Void) { completion("Test finished") }
    func agentJobRows() -> [AgentJobRow] { jobs }
    func agentAutomationModels() -> [OpenRouterModel] { [] }
    func refreshAgentAutomationModels(completion: @escaping ([OpenRouterModel]) -> Void) {}
    func agentAutomationDefaults() -> AgentAutomationDefaults { AgentAutomationDefaults(runtime: .codex, modelID: "test/model") }
    func createAgentAutomation(_ draft: AgentAutomationDraft) throws -> String {
        createdAutomations += 1
        let id = "job-\(createdAutomations)"
        jobs.append(AgentJobRow(id: id, name: draft.name, preview: "Ready", time: "", updatedAt: Date(),
                               assistantName: "FLORA", assistantSlug: draft.assistantSlug, state: .completed,
                               isEnabled: draft.enabled, runtime: draft.runtime, trigger: draft.trigger,
                               modelID: draft.modelID, prompt: draft.prompt, nextRunAt: nil,
                               intervalSeconds: draft.intervalSeconds, dailyTimeMinutes: draft.dailyTimeMinutes,
                               dailyBudgetUSD: draft.dailyBudgetUSD, spentTodayUSD: 0,
                               maxDurationSeconds: draft.maxDurationSeconds, maxAttempts: draft.maxAttempts,
                               hasPendingTrigger: false, runs: [], selectedSourceIDs: draft.selectedSourceIDs,
                               sourceAccessMode: draft.sourceAccessMode))
        return id
    }
    func updateAgentAutomation(id: String, draft: AgentAutomationDraft) throws {}
    func duplicateAgentAutomation(id: String) throws -> String { id }
    func deleteAgentAutomation(id: String) throws {}
    func runAgentJob(_ jobId: String) {}
    func cancelAgentJob(_ jobId: String) {}
    func setAgentJob(_ jobId: String, enabled: Bool) {}
    func assistantWorkspace(slug: String) throws -> AssistantWorkspaceSnapshot {
        let definition = AssistantDefinition(slug: slug, name: assistant.name, description: assistant.description,
            voice: assistant.voice, instructions: assistant.instructions,
            directory: VoiceFlowPaths.shared.directory("editor-fixture"), selectedSkills: assistant.selectedSkills,
            selectedSourceIDs: assistant.selectedSourceIDs, sourceAccessMode: assistant.sourceAccessMode)
        return AssistantWorkspaceSnapshot(
            document: AssistantDocument(definition: definition, fields: [:], fieldOrder: [], revision: "settings-\(documentVersion)"),
            coreMemory: AgentMemoryDocument(kind: "core", content: core, revision: "core-\(coreVersion)", clipped: false),
            ledger: AgentMemoryDocument(kind: "ledger", content: ledger, revision: "ledger-\(ledgerVersion)", clipped: false),
            skills: [AssistantWorkspaceSkill(name: "research", description: "Fixture skill",
                                            selected: assistant.selectedSkills.contains("research"), error: nil)],
            conversations: [], jobs: [])
    }
    func createAgentAssistant(_ draft: AssistantDraft) throws -> String { createdAssistants += 1; assistant = draft; return "flora" }
    func duplicateAgentAssistant(slug: String, name: String) throws -> String { slug }
    func updateAgentAssistant(slug: String, draft: AssistantDraft, expectedRevision: String) throws {
        lastSettingsRevision = expectedRevision
        guard expectedRevision == "settings-\(documentVersion)" else { throw NSError(domain: "Fixture conflict", code: 1) }
        assistant = draft
        documentVersion += 1
        afterAssistantUpdate?()
    }
    func updateAgentAssistantMemory(slug: String, kind: String, content: String, expectedRevision: String) throws -> AgentMemoryDocument {
        lastMemoryRevision = expectedRevision
        let version = kind == "core" ? coreVersion : ledgerVersion
        guard expectedRevision == "\(kind)-\(version)" else { throw NSError(domain: "Fixture conflict", code: 1) }
        if kind == "core" { core = content; coreVersion += 1 } else { ledger = content; ledgerVersion += 1 }
        return AgentMemoryDocument(kind: kind, content: content, revision: "\(kind)-\(version + 1)", clipped: false)
    }
    func createAgentAssistantConversation(slug: String) throws -> String { "fixture-thread" }
    func deleteAgentAssistant(slug: String) throws -> AssistantDeletionOutcome {
        AssistantDeletionOutcome(disabledAutomationCount: 0, retainedConversationCount: 0)
    }
}

private func editorViews(_ root: NSView) -> [NSView] { root.subviews.flatMap { [$0] + editorViews($0) } }

func runWorkspaceEditorTests() {
    let source = WorkspaceEditorDataSource()
    let view = AgentsView(frame: NSRect(x: 0, y: 0, width: 540, height: 540))
    view.dataSource = source
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.contentView = view
    view.useWorkspaceNavigation()
    func button(_ title: String) -> NSButton {
        guard let button = editorViews(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == title }) else {
            fatalError("Missing editor action: \(title)")
        }
        return button
    }
    func click(_ title: String) { button(title).performClick(nil) }
    func field(_ placeholder: String) -> NSTextField {
        guard let field = editorViews(view).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == placeholder }) else {
            fatalError("Missing editor field: \(placeholder)")
        }
        return field
    }
    func textEditor() -> NSTextView {
        editorViews(view).compactMap { $0 as? NSTextView }.first(where: { $0.isEditable })!
    }
    func navigate(_ destination: String, action: String? = nil, system: String? = nil) {
        _ = view.qaNavigate(destination: destination, automationAction: action, jobID: nil,
                            threadSource: nil, threadID: nil, threadFilter: nil, systemAgent: system)
    }
    func memory() { view.showSourceConsumer(.assistant(slug: "flora")); click("Memory & Skills") }

    navigate("assistants", system: "speech_cleanup")
    _ = view.qaSystemAgentEdit(model: "unsaved-model", effort: "high", instructions: "Unsaved system instructions")
    view.refresh()
    expect(view.qaSystemAgentState()["editor_model"] as? String == "unsaved-model", "refresh discarded system model draft")
    expect(view.qaSystemAgentState()["editor_instructions"] as? String == "Unsaved system instructions", "refresh discarded system instructions")
    _ = view.qaSystemAgentAction("test")
    expect(view.qaSystemAgentState()["editor_model"] as? String == "unsaved-model", "Test now discarded system draft")
    _ = view.qaSystemAgentAction("save")
    expect(source.systemModel == "unsaved-model", "system draft was not saved")
    source.systemModel = "externally-updated-model"
    view.refresh()
    expect(view.qaSystemAgentState()["editor_model"] as? String == "externally-updated-model", "clean saved system form masked external update")

    memory()
    textEditor().string = "Core draft"
    button("research").state = .on
    view.refresh()
    expect(button("research").state == .on, "refresh discarded skill selection")
    click("Ledger")
    textEditor().string = "Ledger draft"
    click("Core")
    expect(textEditor().string == "Core draft", "Core/Ledger switch discarded Core draft")
    click("Save memory")
    expect(source.core == "Core draft", "memory draft was not saved")
    expect(button("research").state == .on, "saving memory discarded skill selection")
    click("Ledger")
    expect(textEditor().string == "Ledger draft", "saving Core discarded Ledger draft")
    click("Save skills")
    expect(textEditor().string == "Ledger draft", "saving skills discarded memory draft")
    expect(source.assistant.selectedSkills == ["research"], "skill selection was not saved")
    source.ledgerVersion += 1
    source.ledger = "Externally updated ledger"
    view.refresh()
    click("Save memory")
    expect(source.lastMemoryRevision == "ledger-1", "refresh rebased unsaved memory onto a newer revision")
    expect(source.ledger == "Externally updated ledger", "stale memory overwrote an external change")
    expect(textEditor().string == "Ledger draft", "memory conflict discarded the draft")
    click("Reload saved memory")
    expect(textEditor().string == "Externally updated ledger", "memory conflict has no explicit reload recovery")

    view.showSourceConsumer(.assistant(slug: "flora"))
    let name = field("Assistant name")
    name.stringValue = "Unsaved name"
    window.makeFirstResponder(name)
    (name.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 3))
    view.refresh()
    let refreshedName = field("Assistant name")
    expect(refreshedName.currentEditor() != nil, "refresh lost form field focus")
    expect((refreshedName.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location: 2, length: 3), "refresh lost field selection")
    source.documentVersion += 1
    view.refresh()
    click("Save settings")
    expect(source.lastSettingsRevision == "settings-2", "refresh rebased unsaved settings onto a newer revision")
    expect(source.assistant.name == "FLORA", "stale settings overwrote external revision")
    click("Reload saved settings")
    expect(field("Assistant name").stringValue == "FLORA", "settings conflict has no explicit reload recovery")

    navigate("automations", action: "new")
    field("Morning operating brief").stringValue = "Daily fixture"
    textEditor().string = "Do the fixture task"
    let trigger = editorViews(view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Automation trigger" }!
    trigger.selectItem(at: trigger.itemArray.firstIndex { ($0.representedObject as? String) == AgentJobTriggerKind.daily.rawValue }!)
    _ = NSApp.sendAction(trigger.action!, to: trigger.target, from: trigger)
    _ = view.qaSourceSelection(["selected_source_ids": [], "source_access_mode": AgentSourceAccessMode.reviewCopies.rawValue])
    navigate("now")
    navigate("automations", action: "new")
    expect(field("08:00").isEnabled && !field("60").isEnabled, "restored automation trigger has stale enabled fields")
    let model = editorViews(view).compactMap { $0 as? OpenRouterModelComboBox }.first!
    expect(model.isEnabled, "restored review-copies mode left model disabled")
    expect(editorViews(view).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == AgentSourceAccessMode.reviewCopies.detail }),
           "restored source mode left its explanation stale")
    model.stringValue = "test/model"
    click("Create automation")
    expect(source.createdAutomations == 1, "valid automation was not created")
    navigate("automations", action: "new")
    expect(field("Morning operating brief").stringValue.isEmpty && textEditor().string.isEmpty,
           "reopening New automation resurrected the submitted draft")

    for width: CGFloat in [470, 700] {
        window.setContentSize(NSSize(width: width, height: 540))
        view.layoutSubtreeIfNeeded()
        for control in editorViews(view).compactMap({ $0 as? NSControl }).filter({
            (($0 as? NSTextField)?.isEditable == true || $0 is NSPopUpButton) && !$0.isHidden
        }) {
            let bounds = control.convert(control.bounds, to: view)
            expect(bounds.width > 20 && bounds.minX >= 0 && bounds.maxX <= view.bounds.width + 1,
                   "editable control exceeded the form width at \(width): \(bounds)")
            expect(!(control.accessibilityLabel() ?? "").isEmpty, "editable field is missing an accessibility label")
        }
        expect(!(textEditor().accessibilityLabel() ?? "").isEmpty, "instructions editor is missing an accessibility label")
        saveUIPreview(view, name: "automation-\(Int(width))")
    }

    func newAssistant() {
        navigate("assistants")
        guard let row = editorViews(view).first(where: {
            $0.accessibilityRole() == .button && ($0.accessibilityLabel() ?? "").hasPrefix("New assistant")
        }) else { fatalError("Missing New assistant row") }
        expect(row.accessibilityPerformPress(), "New assistant row did not activate")
    }
    newAssistant()
    field("Research Helper").stringValue = "Created fixture"
    textEditor().string = "Created instructions"
    click("Create assistant")
    expect(source.createdAssistants == 1, "assistant was not created")
    newAssistant()
    expect(field("Research Helper").stringValue.isEmpty && textEditor().string.isEmpty,
           "reopening New assistant resurrected the submitted draft")

    // A settings conflict is rendered above a long form. Saving from the
    // bottom must reveal it once without making subsequent refreshes jump.
    source.sourceOptions = (0..<12).map {
        SourceSelectionOption(id: "fixture-\($0)", title: "Fixture source \($0)", detail: "Collected reference text")
    }
    window.setContentSize(NSSize(width: 470, height: 540))
    view.showSourceConsumer(.assistant(slug: "flora"))
    field("Assistant name").stringValue = "Conflict draft"
    window.makeFirstResponder(nil)
    view.layoutSubtreeIfNeeded()
    button("Save settings").scrollToVisible(button("Save settings").bounds)
    let formScroll = button("Save settings").enclosingScrollView!
    expect(formScroll.contentView.bounds.origin.y > 300, "long-form fixture was not scrolled to its save action")
    source.documentVersion += 1
    click("Save settings")
    func errorIsVisible() -> Bool {
        guard let label = editorViews(view).compactMap({ $0 as? NSTextField }).first(where: {
            $0.stringValue.contains("Fixture conflict")
        }), let scroll = label.enclosingScrollView, let document = scroll.documentView else { return false }
        return label.convert(label.bounds, to: document).intersects(scroll.documentVisibleRect)
    }
    expect(errorIsVisible(), "new save error remained outside the visible form viewport")
    expect(field("Assistant name").stringValue == "Conflict draft", "revealing a save error discarded the draft")
    saveUIPreview(view, name: "settings-error-visible")
    button("Save settings").scrollToVisible(button("Save settings").bounds)
    let readingPosition = formScroll.contentView.bounds.origin
    view.refresh()
    expect(abs(formScroll.contentView.bounds.origin.y - readingPosition.y) < 1,
           "an unchanged error yanked the form back during refresh")
    click("Save settings")
    expect(errorIsVisible(), "retrying Save did not reveal its repeated failure")
    click("Reload saved settings")

    // A successful sibling-section save must not rebase an older draft onto
    // an unrelated external edit that lands immediately after that save.
    let settingsRevision = "settings-\(source.documentVersion)"
    field("Assistant name").stringValue = "Unsaved sibling settings"
    click("Memory & Skills")
    button("research").state = .on
    source.afterAssistantUpdate = { [weak source] in
        guard let source else { return }
        source.afterAssistantUpdate = nil
        let saved = source.assistant
        source.assistant = AssistantDraft(name: "External assistant name", description: saved.description,
            voice: saved.voice, instructions: saved.instructions, selectedSkills: saved.selectedSkills,
            selectedSourceIDs: saved.selectedSourceIDs, sourceAccessMode: saved.sourceAccessMode)
        source.documentVersion += 1
    }
    click("Save skills")
    click("Settings")
    click("Save settings")
    expect(source.lastSettingsRevision == settingsRevision, "sibling save rebased an unsaved draft onto an external revision")
    expect(source.assistant.name == "External assistant name", "unsaved sibling draft overwrote the intervening external change")
    window.close()
    print("PASS: workspace editor drafts, revisions, focus, independent saves and restored controls")
}
