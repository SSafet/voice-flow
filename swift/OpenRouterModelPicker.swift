import Cocoa
import SwiftUI

/// Shared searchable OpenRouter picker used by Settings and the automation
/// editor. The visible value is friendly, while callers always receive the
/// exact provider/model ID required by OpenCode and durable jobs.
final class OpenRouterModelComboBox: NSComboBox,
    NSComboBoxDataSource, NSComboBoxDelegate {
    private(set) var allModels: [OpenRouterModel] = []
    private(set) var filteredModels: [OpenRouterModel] = []
    private(set) var committedModelID: String?

    var onModelSelected: ((OpenRouterModel) -> Void)?
    var onQueryChanged: ((OpenRouterModel?) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        usesDataSource = true
        dataSource = self
        delegate = self
        isEditable = true
        completes = false
        numberOfVisibleItems = 16
        itemHeight = 24
        font = .systemFont(ofSize: 12)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        usesDataSource = true
        dataSource = self
        delegate = self
        isEditable = true
        completes = false
        numberOfVisibleItems = 16
        itemHeight = 24
        font = .systemFont(ofSize: 12)
    }

    func configure(models: [OpenRouterModel], selectedID: String) {
        let changed = allModels.map(\.id) != models.map(\.id)
        allModels = models
        if changed {
            filteredModels = models
            noteNumberOfItemsChanged()
        }

        let normalized = selectedID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard committedModelID != normalized || stringValue.isEmpty else { return }
        committedModelID = normalized
        if let model = allModels.first(where: { $0.id == normalized }) {
            stringValue = model.displayLabel
        } else {
            stringValue = normalized
        }
    }

    var selectedModelID: String? {
        let raw = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = exactModel(for: raw) { return exact.id }
        guard raw.contains("/"), !raw.contains(" "), !raw.contains("—") else { return nil }
        return raw
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int { filteredModels.count }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        filteredModels.indices.contains(index) ? filteredModels[index].displayLabel : nil
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === self else { return }
        let query = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredModels = allModels
        } else {
            filteredModels = allModels.filter {
                $0.id.localizedCaseInsensitiveContains(query)
                    || $0.name.localizedCaseInsensitiveContains(query)
            }
        }
        noteNumberOfItemsChanged()
        onQueryChanged?(exactModel(for: query) ?? filteredModels.first)
    }

    func comboBoxWillPopUp(_ notification: Notification) {
        let raw = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || exactModel(for: raw)?.id == committedModelID {
            filteredModels = allModels
            noteNumberOfItemsChanged()
        }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === self,
              filteredModels.indices.contains(indexOfSelectedItem) else { return }
        select(filteredModels[indexOfSelectedItem], notify: true)
    }

    @discardableResult
    func selectModel(id: String, notify: Bool = true) -> Bool {
        guard let model = allModels.first(where: { $0.id == id }) else { return false }
        select(model, notify: notify)
        return true
    }

    private func select(_ model: OpenRouterModel, notify: Bool) {
        committedModelID = model.id
        stringValue = model.displayLabel
        filteredModels = allModels
        noteNumberOfItemsChanged()
        onQueryChanged?(model)
        if notify { onModelSelected?(model) }
    }

    private func exactModel(for value: String) -> OpenRouterModel? {
        allModels.first {
            $0.id.caseInsensitiveCompare(value) == .orderedSame
                || $0.displayLabel.caseInsensitiveCompare(value) == .orderedSame
        }
    }
}

/// SwiftUI bridge that keeps the Settings value as an exact model ID while
/// retaining the native editable combo-box search and dropdown behavior.
struct OpenRouterModelPicker: NSViewRepresentable {
    @Binding var selection: String
    let models: [OpenRouterModel]

    final class Coordinator {
        var parent: OpenRouterModelPicker
        init(_ parent: OpenRouterModelPicker) { self.parent = parent }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> OpenRouterModelComboBox {
        let combo = OpenRouterModelComboBox()
        combo.setAccessibilityLabel("Default OpenCode model")
        combo.setAccessibilityHelp(
            "Search the current OpenRouter catalog and choose the default OpenCode model.")
        combo.onModelSelected = { [weak coordinator = context.coordinator] model in
            coordinator?.parent.selection = model.id
        }
        combo.configure(models: models, selectedID: selection)
        return combo
    }

    func updateNSView(_ combo: OpenRouterModelComboBox, context: Context) {
        context.coordinator.parent = self
        combo.configure(models: models, selectedID: selection)
    }
}
