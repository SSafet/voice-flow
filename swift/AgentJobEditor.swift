import Cocoa

/// Compact AppKit editor embedded in the existing automation alert. The model
/// field is an editable, filtered combo box: catalog rows are searchable and
/// an exact OpenRouter model ID remains valid when the network is unavailable.
final class AgentJobEditorView: NSView, NSComboBoxDataSource, NSComboBoxDelegate {
    let promptField = NSTextField(string: "")
    let runtimePopUp = NSComboBox()
    let triggerPopUp = NSComboBox()
    let intervalField = NSTextField(string: "60")
    let budgetField = NSTextField(string: "1.00")
    let modelCombo = NSComboBox()

    private let modelStatus = NSTextField(wrappingLabelWithString: "")
    private let modelDetail = NSTextField(labelWithString: "")
    private let catalogStatus: String
    private let allModels: [OpenRouterModel]
    private var filteredModels: [OpenRouterModel]

    init(models: OpenRouterModelCatalogResult,
         preferredRuntime: AgentRuntimeKind,
         defaultModelID: String) {
        allModels = models.models
        filteredModels = models.models
        catalogStatus = models.statusText
        super.init(frame: NSRect(x: 0, y: 0, width: 470, height: 216))
        appearance = NSAppearance(named: .darkAqua)

        promptField.placeholderString = "What should the assistant do?"
        promptField.setAccessibilityLabel("Automation prompt")
        runtimePopUp.addItems(withObjectValues: AgentRuntimeKind.allCases.map(\.label))
        runtimePopUp.selectItem(
            at: AgentRuntimeKind.allCases.firstIndex(of: preferredRuntime) ?? 0)
        runtimePopUp.isEditable = false
        runtimePopUp.setAccessibilityLabel("Automation runtime")
        runtimePopUp.target = self
        runtimePopUp.action = #selector(runtimeChanged)
        triggerPopUp.addItems(withObjectValues: [
            "Manual", "Interval", "Inbox message", "Capture completed", "Watcher action",
        ])
        triggerPopUp.selectItem(at: 0)
        triggerPopUp.isEditable = false
        triggerPopUp.setAccessibilityLabel("Automation trigger")
        runtimePopUp.numberOfVisibleItems = AgentRuntimeKind.allCases.count
        triggerPopUp.numberOfVisibleItems = 5
        runtimePopUp.font = .systemFont(ofSize: 12)
        triggerPopUp.font = .systemFont(ofSize: 12)
        intervalField.setAccessibilityLabel("Automation interval in minutes")
        budgetField.setAccessibilityLabel("Automation daily budget in US dollars")

        modelCombo.usesDataSource = true
        modelCombo.dataSource = self
        modelCombo.delegate = self
        modelCombo.completes = false
        modelCombo.numberOfVisibleItems = 14
        modelCombo.setAccessibilityLabel("OpenCode model")
        if let preferred = allModels.first(where: { $0.id == defaultModelID }) {
            modelCombo.stringValue = preferred.displayLabel
            modelDetail.stringValue = preferred.detail
        } else {
            modelCombo.stringValue = defaultModelID
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
        grid.column(at: 1).width = 350
        runtimeChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    var selectedRuntime: AgentRuntimeKind {
        AgentRuntimeKind.allCases[
            min(max(runtimePopUp.indexOfSelectedItem, 0), AgentRuntimeKind.allCases.count - 1)]
    }

    var selectedModelID: String? {
        guard selectedRuntime == .opencode else { return nil }
        let raw = modelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = allModels.first(where: {
            $0.id.caseInsensitiveCompare(raw) == .orderedSame
                || $0.displayLabel.caseInsensitiveCompare(raw) == .orderedSame
        }) { return exact.id }
        // Manual fallback is deliberately exact-ID shaped. It must not turn a
        // half-written natural-language search into a durable model choice.
        guard raw.contains("/"), !raw.contains(" "), !raw.contains("—") else { return nil }
        return raw
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int { filteredModels.count }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        filteredModels.indices.contains(index) ? filteredModels[index].displayLabel : nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === modelCombo else { return }
        let query = modelCombo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredModels = allModels
        } else {
            filteredModels = allModels.filter {
                $0.id.localizedCaseInsensitiveContains(query)
                    || $0.name.localizedCaseInsensitiveContains(query)
            }
        }
        modelCombo.noteNumberOfItemsChanged()
        if let exact = allModels.first(where: {
            $0.id.caseInsensitiveCompare(query) == .orderedSame
                || $0.displayLabel.caseInsensitiveCompare(query) == .orderedSame
        }) {
            modelDetail.stringValue = exact.detail
        } else {
            modelDetail.stringValue = filteredModels.first?.detail ?? "Type an exact provider/model ID"
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === modelCombo,
              filteredModels.indices.contains(modelCombo.indexOfSelectedItem) else { return }
        let model = filteredModels[modelCombo.indexOfSelectedItem]
        modelCombo.stringValue = model.displayLabel
        modelDetail.stringValue = model.detail
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
    var qaFilteredModelIDs: [String] { filteredModels.map(\.id) }

    func qaSelectModel(id: String) -> Bool {
        guard let model = allModels.first(where: { $0.id == id }) else { return false }
        filteredModels = allModels
        modelCombo.noteNumberOfItemsChanged()
        modelCombo.stringValue = model.displayLabel
        modelDetail.stringValue = model.detail
        return true
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
