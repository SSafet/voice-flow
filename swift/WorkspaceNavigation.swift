import Cocoa

/// Durable workspace destinations. The pill continues to own quick interaction.
enum WorkspaceDestination: String, CaseIterable {
    case now, inbox, threads, sources, assistants, automations, speech, settings

    var label: String {
        switch self {
        case .sources: return "Data"
        default: return rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
    var symbol: String {
        switch self {
        case .now: return "circle.dotted"
        case .inbox: return "tray"
        case .threads: return "text.bubble"
        case .sources: return "externaldrive"
        case .assistants: return "sparkles"
        case .automations: return "clock.arrow.circlepath"
        case .speech: return "speaker.wave.2"
        case .settings: return "gearshape"
        }
    }
}

final class WorkspaceSidebar: NSView {
    var onSelect: ((WorkspaceDestination) -> Void)?
    private var buttons: [WorkspaceDestination: NSButton] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.bgLighter.withAlphaComponent(0.4).cgColor
        let title = NSTextField(labelWithString: "Voice Flow")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Theme.text
        let caption = NSTextField(labelWithString: "YOUR WORKSPACE")
        caption.font = .systemFont(ofSize: 9.5, weight: .medium)
        caption.textColor = Theme.text2
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(title)
        column.setCustomSpacing(7, after: title)
        column.addArrangedSubview(caption)
        column.setCustomSpacing(24, after: caption)
        for destination in WorkspaceDestination.allCases {
            if destination == .sources {
                let separator = NSView()
                separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
                column.addArrangedSubview(separator)
            }
            if destination == .speech {
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
                column.addArrangedSubview(spacer)
            }
            let button = NSButton(title: destination.label, target: self, action: #selector(selected(_:)))
            button.image = NSImage(systemSymbolName: destination.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            button.imagePosition = .imageLeading
            button.imageHugsTitle = false
            button.alignment = .left
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.identifier = NSUserInterfaceItemIdentifier(destination.rawValue)
            button.setAccessibilityLabel("Open \(destination.label)")
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            column.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            buttons[destination] = button
        }
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
        select(.now)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(_ destination: WorkspaceDestination, inboxCount: Int = 0, attentionCount: Int = 0) {
        for (item, button) in buttons {
            let count = item == .inbox ? inboxCount : item == .now ? attentionCount : 0
            button.title = "  \(item.label)" + (count > 0 ? "  \(count)" : "")
            button.contentTintColor = item == destination ? Theme.accent : Theme.text2
            button.layer?.backgroundColor = item == destination ? Theme.accentGlow.cgColor : NSColor.clear.cgColor
            button.setAccessibilityValue(item == destination ? "Selected" : "")
        }
    }
    @objc private func selected(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let destination = WorkspaceDestination(rawValue: raw) else { return }
        onSelect?(destination)
    }
}
