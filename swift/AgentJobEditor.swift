import Cocoa

/// Compact AppKit editor embedded in the existing automation alert. The model
/// field is an editable, filtered combo box: catalog rows are searchable and
/// an exact OpenRouter model ID remains valid when the network is unavailable.
final class AgentJobEditorView: NSView {
    private static let triggerChoices: [(label: String, kind: AgentJobTriggerKind)] = [
        ("Manual", .manual),
        ("Interval", .interval),
        ("Daily at time", .daily),
        ("Inbox message", .inbox),
        ("Capture completed", .capture),
        ("Watcher action", .watcher),
    ]

    let promptField = NSTextField(string: "")
    let runtimePopUp = NSPopUpButton()
    let triggerPopUp = NSPopUpButton()
    let intervalField = NSTextField(string: "60")
    let dailyTimeField = NSTextField(string: "08:00")
    let budgetField = NSTextField(string: "1.00")
    let modelCombo = OpenRouterModelComboBox()
    let effortPopUp = NSPopUpButton()

    private let modelStatus = NSTextField(wrappingLabelWithString: "")
    private let modelDetail = NSTextField(labelWithString: "")
    private let catalogStatus: String
    private let allModels: [OpenRouterModel]

    init(models: OpenRouterModelCatalogResult,
         preferredRuntime: AgentRuntimeKind,
         defaultModelID: String,
         defaultReasoningEffort: String = AgentReasoningEffort.unset) {
        allModels = models.models
        catalogStatus = models.statusText
        super.init(frame: NSRect(x: 0, y: 0, width: 590, height: 275))
        appearance = NSAppearance(named: .darkAqua)

        promptField.placeholderString = "What should the assistant do?"
        promptField.setAccessibilityLabel("Automation prompt")
        runtimePopUp.addItems(withTitles: AgentRuntimeKind.allCases.map(\.label))
        runtimePopUp.selectItem(
            at: AgentRuntimeKind.allCases.firstIndex(of: preferredRuntime) ?? 0)
        runtimePopUp.setAccessibilityLabel("Automation runtime")
        runtimePopUp.target = self
        runtimePopUp.action = #selector(runtimeChanged)
        triggerPopUp.addItems(withTitles: Self.triggerChoices.map(\.label))
        triggerPopUp.selectItem(at: 0)
        triggerPopUp.setAccessibilityLabel("Automation trigger")
        effortPopUp.addItems(withTitles: AgentReasoningEffort.choices.map(\.label))
        effortPopUp.selectItem(
            at: AgentReasoningEffort.choices.firstIndex {
                $0.value == (AgentReasoningEffort.normalized(defaultReasoningEffort)
                             ?? AgentReasoningEffort.unset)
            } ?? 0)
        effortPopUp.setAccessibilityLabel("Automation reasoning effort")
        effortPopUp.toolTip =
            "How hard the model should think on every run. Provider-specific; ignored by models without the knob."
        for popUp in [runtimePopUp, triggerPopUp, effortPopUp] {
            popUp.font = .systemFont(ofSize: 12)
            popUp.isBordered = false
            popUp.alignment = .left
            popUp.contentTintColor = Theme.text
            popUp.wantsLayer = true
            popUp.layer?.backgroundColor = Theme.cardHover.cgColor
            popUp.layer?.cornerRadius = 6
        }
        intervalField.setAccessibilityLabel("Automation interval in minutes")
        dailyTimeField.setAccessibilityLabel("Automation daily run time (HH:MM)")
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
            [NSTextField(labelWithString: "Reasoning"), effortPopUp],
            [NSTextField(labelWithString: "Trigger"), triggerPopUp],
            [NSTextField(labelWithString: "Interval min"), intervalField],
            [NSTextField(labelWithString: "Daily at (HH:MM)"), dailyTimeField],
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
        for control in [runtimePopUp, triggerPopUp, effortPopUp] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 240).isActive = true
        }
        for control in [promptField, modelCombo, intervalField, dailyTimeField, budgetField] {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 470).isActive = true
        }
        runtimeChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedRuntime: AgentRuntimeKind {
        let visibleValue = (runtimePopUp.titleOfSelectedItem ?? runtimePopUp.title)
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
        let visibleValue = (triggerPopUp.titleOfSelectedItem ?? triggerPopUp.title)
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

    var selectedDailyTimeMinutes: Int? {
        AgentDailyTime.minutes(from: dailyTimeField.stringValue)
    }

    var selectedModelID: String? {
        guard selectedRuntime == .opencode else { return nil }
        return modelCombo.selectedModelID
    }

    /// Unlike the model, effort applies to both runtimes — codex takes it as
    /// `model_reasoning_effort` while still choosing its own model.
    var selectedReasoningEffort: String? {
        let visibleValue = (effortPopUp.titleOfSelectedItem ?? effortPopUp.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let choice = AgentReasoningEffort.choices.first {
            $0.label.caseInsensitiveCompare(visibleValue) == .orderedSame
        } ?? AgentReasoningEffort.choices[
            min(max(effortPopUp.indexOfSelectedItem, 0),
                AgentReasoningEffort.choices.count - 1)]
        return AgentReasoningEffort.normalized(choice.value)
    }

    @objc private func runtimeChanged() {
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

    func qaSelectRuntime(_ runtime: AgentRuntimeKind) {
        runtimePopUp.selectItem(
            at: AgentRuntimeKind.allCases.firstIndex(of: runtime) ?? 0)
        runtimePopUp.sendAction(runtimePopUp.action, to: runtimePopUp.target)
    }

    func qaSetVisibleTrigger(_ label: String) {
        triggerPopUp.selectItem(withTitle: label)
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
