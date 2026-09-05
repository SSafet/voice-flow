import Cocoa

struct SourceSelectionOption {
    let id: String
    let title: String
    let detail: String
}

final class SourceSelectionView: NSView {
    private var buttons: [String: NSButton] = [:]
    private let access = NSPopUpButton()
    private let explanation = NSTextField(wrappingLabelWithString: "")
    var onChange: (() -> Void)?
    var selectedIDs: [String] { buttons.filter { $0.value.state == .on }.map(\.key).sorted() }
    var selectedMode: AgentSourceAccessMode {
        AgentSourceAccessMode(rawValue: access.selectedItem?.representedObject as? String ?? "") ?? .standard
    }
    init(options: [SourceSelectionOption], selectedIDs: [String], mode: AgentSourceAccessMode) {
        super.init(frame: .zero)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)])
        let note = NSTextField(wrappingLabelWithString: "Each selected source supplies its collected text and usage instructions. Configure connections in Data.")
        note.font = .systemFont(ofSize: 12); note.textColor = Theme.text2
        stack.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        var rows = options
        for id in selectedIDs where !options.contains(where: { $0.id == id }) {
            rows.append(SourceSelectionOption(id: id, title: "Unavailable source", detail: "Remove this selection or reconnect its source: \(id)"))
        }
        for option in rows {
            let check = NSButton(checkboxWithTitle: option.title, target: self, action: #selector(changed))
            check.identifier = NSUserInterfaceItemIdentifier("source-selection-" + option.id)
            check.state = selectedIDs.contains(option.id) ? .on : .off
            check.contentTintColor = Theme.text; check.toolTip = option.detail
            check.setAccessibilityLabel("Data source: " + option.title)
            buttons[option.id] = check; stack.addArrangedSubview(check)
            let detail = NSTextField(wrappingLabelWithString: option.detail)
            detail.font = .systemFont(ofSize: 11); detail.textColor = Theme.text2
            stack.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for kind in AgentSourceAccessMode.allCases {
            access.addItem(withTitle: kind.label); access.lastItem?.representedObject = kind.rawValue
        }
        access.selectItem(at: AgentSourceAccessMode.allCases.firstIndex(of: mode) ?? 0)
        access.identifier = NSUserInterfaceItemIdentifier("source-access-mode")
        access.target = self; access.action = #selector(changed)
        access.setAccessibilityLabel("Data access mode")
        stack.addArrangedSubview(access)
        explanation.font = .systemFont(ofSize: 12); explanation.textColor = Theme.text2
        stack.addArrangedSubview(explanation); explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        explanation.stringValue = mode.detail
    }
    required init?(coder: NSCoder) { fatalError() }
    func select(ids: [String], mode: AgentSourceAccessMode) {
        for (id, button) in buttons { button.state = ids.contains(id) ? .on : .off }
        access.selectItem(at: AgentSourceAccessMode.allCases.firstIndex(of: mode) ?? 0)
        changed()
    }
    @objc private func changed() { explanation.stringValue = selectedMode.detail; onChange?() }
}
