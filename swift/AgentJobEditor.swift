import Cocoa

/// Compact AppKit editor embedded in the existing automation alert. The model
/// field is an editable, filtered combo box: catalog rows are searchable and
/// an exact OpenRouter model ID remains valid when the network is unavailable.
final class AgentJobEditorView: NSView {
    private static let triggerChoices: [(label: String, kind: AgentJobTriggerKind)] = [
        ("Manual", .manual),
        ("Interval", .interval),
        ("Inbox message", .inbox),
        ("Capture completed", .capture),
        ("Watcher action", .watcher),
    ]

    let promptField = NSTextField(string: "")
    let runtimePopUp = NSComboBox()
    let triggerPopUp = NSComboBox()
    let intervalField = NSTextField(string: "60")
    let budgetField = NSTextField(string: "1.00")
    let modelCombo = OpenRouterModelComboBox()

    private let modelStatus = NSTextField(wrappingLabelWithString: "")
    private let modelDetail = NSTextField(labelWithString: "")
    private let catalogStatus: String
    private let allModels: [OpenRouterModel]

    init(models: OpenRouterModelCatalogResult,
         preferredRuntime: AgentRuntimeKind,
         defaultModelID: String) {
        allModels = models.models
        catalogStatus = models.statusText
        super.init(frame: NSRect(x: 0, y: 0, width: 590, height: 216))
        appearance = NSAppearance(named: .darkAqua)

        promptField.placeholderString = "What should the assistant do?"
        promptField.setAccessibilityLabel("Automation prompt")
        runtimePopUp.addItems(withObjectValues: AgentRuntimeKind.allCases.map(\.label))
        runtimePopUp.selectItem(
            at: AgentRuntimeKind.allCases.firstIndex(of: preferredRuntime) ?? 0)
        runtimePopUp.isEditable = false
        runtimePopUp.setAccessibilityLabel("Automation runtime")
        runtimePopUp.target = self
        runtimePopUp.action = #selector(runtimeSelectionChanged)
        triggerPopUp.addItems(withObjectValues: Self.triggerChoices.map(\.label))
        triggerPopUp.selectItem(at: 0)
        triggerPopUp.isEditable = false
        triggerPopUp.setAccessibilityLabel("Automation trigger")
        runtimePopUp.numberOfVisibleItems = AgentRuntimeKind.allCases.count
        triggerPopUp.numberOfVisibleItems = 5
        runtimePopUp.font = .systemFont(ofSize: 12)
        triggerPopUp.font = .systemFont(ofSize: 12)
        intervalField.setAccessibilityLabel("Automation interval in minutes")
        budgetField.setAccessibilityLabel("Automation daily budget in US dollars")

        modelCombo.setAccessibilityLabel("OpenCode model")
        modelCombo.setAccessibilityHelp(
            "Search the current OpenRouter catalog or type an exact provider/model ID.")
        modelCombo.configure(models: allModels, selectedID: defaultModelID)
        modelCombo.onModelSelected = { [weak self] model in
            self?.modelDetail.stringValue = model.detail
        }
        modelCombo.onQueryChanged = { [weak self] model in
            self?.modelDetail.stringValue = model?.detail ?? "Type an exact provider/model ID"
        }
        if let preferred = allModels.first(where: { $0.id == defaultModelID }) {
            modelDetail.stringValue = preferred.detail
        }
        modelStatus.stringValue = catalogStatus
        modelStatus.textColor = models.source == .live ? Theme.text3 : Theme.accent
        modelStatus.font = .systemFont(ofSize: 10.5)
        modelStatus.maximumNumberOfLines = 2
        modelDetail.textColor = Theme.text3
        modelDetail.font = .systemFont(ofSize: 10.5)
        modelDetail.lineBreakMode = .byTruncatingTail

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Prompt"), promptField],
            [NSTextField(labelWithString: "Runtime"), runtimePopUp],
            [NSTextField(labelWithString: "Model"), modelCombo],
            [NSTextField(labelWithString: ""), modelDetail],
            [NSTextField(labelWithString: "Trigger"), triggerPopUp],
            [NSTextField(labelWithString: "Interval min"), intervalField],
            [NSTextField(labelWithString: "Daily budget $"), budgetField],
            [NSTextField(labelWithString: ""), modelStatus],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 7
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        grid.column(at: 1).width = 470
        for control in [runtimePopUp, triggerPopUp] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        for control in [promptField, modelCombo, intervalField, budgetField] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 470).isActive = true
        }
        runtimeChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedRuntime: AgentRuntimeKind {
        let visibleValue = runtimePopUp.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let runtime = AgentRuntimeKind.allCases.first(where: {
            $0.label.caseInsensitiveCompare(visibleValue) == .orderedSame
        }) {
            return runtime
        }
        let index = min(max(runtimePopUp.indexOfSelectedItem, 0),
                        AgentRuntimeKind.allCases.count - 1)
        return AgentRuntimeKind.allCases[index]
    }

    var selectedTrigger: AgentJobTriggerKind {
        let visibleValue = triggerPopUp.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let choice = Self.triggerChoices.first(where: {
            $0.label.caseInsensitiveCompare(visibleValue) == .orderedSame
        }) {
            return choice.kind
        }
        let index = min(max(triggerPopUp.indexOfSelectedItem, 0),
                        Self.triggerChoices.count - 1)
        return Self.triggerChoices[index].kind
    }

    var selectedModelID: String? {
        guard selectedRuntime == .opencode else { return nil }
        return modelCombo.selectedModelID
    }

    @objc private func runtimeSelectionChanged() {
        // NSComboBox can dispatch its action before indexOfSelectedItem has
        // caught up with the title displayed to the user. Resolve by title on
        // the next main-loop turn so the visible selection is authoritative.
        DispatchQueue.main.async { [weak self] in self?.runtimeChanged() }
    }

    private func runtimeChanged() {
        let enabled = selectedRuntime == .opencode
        modelCombo.isEnabled = enabled
        modelDetail.isEnabled = enabled
        modelStatus.stringValue = enabled
            ? catalogStatus
            : "Codex chooses its model through Codex settings"
        modelCombo.setAccessibilityHelp(
            enabled ? "Search the current OpenRouter catalog or type an exact model ID."
                    : "Codex model selection is managed by Codex.")
    }

#if VOICE_FLOW_QA
    var qaFilteredModelIDs: [String] { modelCombo.filteredModels.map(\.id) }
    var qaModelEnabled: Bool { modelCombo.isEnabled }
    var qaModelStatus: String { modelStatus.stringValue }

    func qaSetVisibleRuntime(_ label: String) {
        runtimePopUp.stringValue = label
        runtimeChanged()
    }

    func qaSetVisibleTrigger(_ label: String) {
        triggerPopUp.stringValue = label
    }

    func qaSelectModel(id: String) -> Bool {
        modelCombo.selectModel(id: id)
    }

    func qaSnapshot() throws -> (path: String, width: Int, height: Int) {
        precondition(Thread.isMainThread)
        layoutSubtreeIfNeeded()
        displayIfNeeded()
        let bounds = self.bounds
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else {
            throw NSError(
                domain: "VoiceFlowQA", code: 31,
                userInfo: [NSLocalizedDescriptionKey: "Automation editor bitmap allocation failed."])
        }
        cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "VoiceFlowQA", code: 32,
                userInfo: [NSLocalizedDescriptionKey: "Automation editor PNG encoding failed."])
        }
        let directory = VoiceFlowPaths.shared.directory("qa-artifacts")
        let url = directory.appendingPathComponent("automation-model-picker.png")
        try png.write(to: url, options: .atomic)
        return (url.path, bitmap.pixelsWide, bitmap.pixelsHigh)
    }
#endif
}
