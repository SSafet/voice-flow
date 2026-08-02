import Cocoa

func vflog(_ message: String) {}

enum AgentRuntimeKind: String, CaseIterable {
    case codex
    case opencode

    var label: String {
        switch self {
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }
}

enum AgentJobTriggerKind: String {
    case manual
    case interval
    case inbox
    case capture
    case watcher
}

enum Theme {
    static let text = NSColor.labelColor
    static let text3 = NSColor.secondaryLabelColor
    static let accent = NSColor.systemOrange
    static let cardHover = NSColor.quaternaryLabelColor
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

private func model(_ id: String, _ name: String) -> OpenRouterModel {
    OpenRouterModel(
        id: id, name: name, contextLength: 128_000, maxCompletionTokens: 32_000,
        inputModalities: ["text"], outputModalities: ["text"],
        promptPrice: "0.000001", completionPrice: "0.000002",
        supportedParameters: ["tools"])
}

let original = [
    model("test/original-zero", "Original zero"),
    model("test/original-one", "Original one"),
    model("openai/gpt-5.6-luna", "OpenAI: GPT-5.6 Luna"),
    model("openai/gpt-5.6-luna-pro", "OpenAI: GPT-5.6 Luna Pro"),
]

let editor = AgentJobEditorView(
    models: OpenRouterModelCatalogResult(
        models: original, source: .live, fetchedAt: Date(), warning: nil),
    preferredRuntime: .codex,
    defaultModelID: "openai/gpt-5.6-luna")
expect(!editor.modelCombo.isEnabled,
       "Codex automation unexpectedly enabled the OpenCode model picker")
editor.runtimePopUp.selectItem(at: 1)
editor.runtimePopUp.sendAction(
    editor.runtimePopUp.action, to: editor.runtimePopUp.target)
RunLoop.main.run(until: Date().addingTimeInterval(0.02))
expect(editor.selectedRuntime == .opencode,
       "runtime popup did not commit the visible OpenCode choice")
expect(editor.modelCombo.isEnabled,
       "real runtime selection event did not enable the OpenCode model picker")
expect(editor.selectedModelID == "openai/gpt-5.6-luna",
       "OpenCode runtime selection lost the configured model ID")

let combo = OpenRouterModelComboBox(frame: NSRect(x: 0, y: 0, width: 470, height: 26))
combo.configure(models: original, selectedID: "test/original-one")

var committed: String?
combo.onModelSelected = { committed = $0.id }
combo.stringValue = "luna"
combo.controlTextDidChange(Notification(
    name: NSControl.textDidChangeNotification, object: combo))
expect(combo.filteredModels.map(\.id) == [
    "openai/gpt-5.6-luna", "openai/gpt-5.6-luna-pro",
], "Luna query did not produce the expected two-row filtered list")

// AppKit reports the selected row while its popup still owns that filtered
// item space. Replacing the data source synchronously here makes the same row
// index point at `test/original-zero`, which is the reported product bug.
combo.selectItem(at: 0)
combo.comboBoxSelectionDidChange(Notification(
    name: NSComboBox.selectionDidChangeNotification, object: combo))
combo.comboBoxWillDismiss(Notification(
    name: NSComboBox.willDismissNotification, object: combo))
RunLoop.main.run(until: Date().addingTimeInterval(0.02))

expect(committed == "openai/gpt-5.6-luna",
       "filtered Luna selection committed a model from the original index space: \(committed ?? "nil")")
expect(combo.selectedModelID == "openai/gpt-5.6-luna",
       "picker text no longer resolves to the chosen Luna model: \(combo.stringValue)")
expect(combo.filteredModels.map(\.id) == original.map(\.id),
       "picker did not restore the full catalog after the filtered popup closed")
print("Automation runtime and OpenRouter model picker selection tests passed")
