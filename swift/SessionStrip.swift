import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Session Strip — persistent picker for connected Claude sessions
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  A small chip row pinned to the bottom-right corner: one numbered chip
//  per connected Claude Code session, the active one highlighted. Click a
//  chip (or press ⌃⌥1–6) to route voice + that session's overlays there.

private final class SessionChipButton: NSButton {
    var sessionId: String?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SessionStrip {
    var onSelect: ((String) -> Void)?

    private var panel: NSPanel?

    /// Re-render the chips (connect/close/rename/switch). Main thread.
    func update(sessions: [MCPSession], activeId: String?) {
        guard !sessions.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let panel = ensurePanel()

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        for (index, session) in sessions.enumerated() {
            let isActive = session.id == activeId
            let chip = SessionChipButton(
                title: " \(index + 1) · \(String(session.label.prefix(22))) ",
                target: self, action: #selector(chipTapped(_:))
            )
            chip.sessionId = session.id
            chip.isBordered = false
            chip.font = .systemFont(ofSize: 10.5, weight: isActive ? .semibold : .regular)
            chip.contentTintColor = isActive ? Theme.text : Theme.text3
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 8
            chip.layer?.backgroundColor = (isActive
                ? Theme.accent.withAlphaComponent(0.22)
                : NSColor.white.withAlphaComponent(0.06)).cgColor
            chip.layer?.borderWidth = isActive ? 1 : 0
            chip.layer?.borderColor = Theme.accent.withAlphaComponent(0.55).cgColor
            chip.toolTip = "Route voice + overlays to \(session.label) (⌃⌥\(index + 1))"
            row.addArrangedSubview(chip)
        }

        let root = NSVisualEffectView()
        root.material = .hudWindow
        root.state = .active
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.cornerRadius = 11
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Theme.border.cgColor

        let size = row.fittingSize
        root.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        row.frame = root.bounds
        row.autoresizingMask = [.width, .height]
        root.addSubview(row)

        let screen = NSScreen.screens.first ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.contentView = root
        panel.setFrame(NSRect(x: visible.maxX - size.width - 12,
                              y: visible.minY + 10,
                              width: size.width, height: size.height), display: true)
        panel.orderFront(nil)
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard let id = (sender as? SessionChipButton)?.sessionId else { return }
        onSelect?(id)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 24),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        newPanel.level = .floating
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false
        panel = newPanel
        return newPanel
    }
}
