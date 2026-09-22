import AppKit

/// Native recovery stays available while the normal app is gated. Buttons use
/// the same controller path for a person and for the isolated signed QA drill.
final class ThreadStoreRecoveryWindow: NSObject, NSWindowDelegate {
    private let reason: String
    private let backup: URL?
    private let choices: [ThreadStoreRecovery.Choice]
    private let onChoice: (ThreadStoreRecovery.Choice) -> Void
    private let onRetry: (() -> Void)?
    private var window: NSWindow?
    private var buttons: [NSButton] = []
    private var status: NSTextField?

    init(report: DamageReport, choices: [ThreadStoreRecovery.Choice],
         onChoice: @escaping (ThreadStoreRecovery.Choice) -> Void) {
        reason = report.reason
        backup = report.newestBackup
        self.choices = choices
        self.onChoice = onChoice
        onRetry = nil
    }

    init(error: String, onRetry: @escaping () -> Void) {
        reason = error
        backup = nil
        choices = []
        onChoice = { _ in }
        self.onRetry = onRetry
    }

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Voice Flow — Thread History"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 420))
        func label(_ text: String, y: CGFloat, height: CGFloat, bold: Bool = false) -> NSTextField {
            let view = NSTextField(wrappingLabelWithString: text)
            view.frame = NSRect(x: 28, y: y, width: 604, height: height)
            view.font = bold ? .boldSystemFont(ofSize: 20) : .systemFont(ofSize: 13)
            content.addSubview(view)
            return view
        }
        _ = label(onRetry == nil ? "Your thread history needs recovery" : "Thread history could not be opened", y: 348, height: 35, bold: true)
        _ = label(onRetry == nil
                  ? "The original database has been kept. Choose how to continue. Your assistant stays paused until a working history is available."
                  : "Your data has been kept. Resolve the problem and retry. Your assistant stays paused while history is unavailable.", y: 288, height: 50)
        let detail = label(reason, y: 212, height: 65)
        detail.textColor = .secondaryLabelColor
        if let backup {
            _ = label("Backup available: \(backup.lastPathComponent)", y: 180, height: 25)
        }
        status = label("", y: 120, height: 52)
        status?.textColor = .systemRed
        for (index, choice) in choices.enumerated() {
            let button = NSButton(title: Self.title(for: choice), target: self, action: #selector(choose(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 28 + CGFloat(index % 2) * 310,
                                  y: 69 - CGFloat(index / 2) * 38, width: 294, height: 32)
            content.addSubview(button)
            buttons.append(button)
        }
        if onRetry != nil {
            let retry = NSButton(title: "Retry Opening History", target: self, action: #selector(retry))
            retry.bezelStyle = .rounded
            retry.frame = NSRect(x: 28, y: 35, width: 294, height: 32)
            content.addSubview(retry)
            buttons.append(retry)
        }
        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    func setBusy(_ busy: Bool, message: String = "") {
        buttons.forEach { $0.isEnabled = !busy }
        status?.textColor = busy ? .secondaryLabelColor : .systemRed
        status?.stringValue = message
    }

    func close() { window?.close(); window = nil }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // There is no normal menu-bar UI while gated. Closing recovery quits
        // safely; the durable report brings this window back on next launch.
        NSApp.terminate(nil)
        return false
    }

    @objc private func retry() { onRetry?() }

    @objc private func choose(_ sender: NSButton) {
        guard choices.indices.contains(sender.tag), sender.isEnabled else { return }
        onChoice(choices[sender.tag])
    }

    private static func title(for choice: ThreadStoreRecovery.Choice) -> String {
        switch choice {
        case .restoreBackup: return "Restore Newest Backup"
        case .repair: return "Try Repair"
        case .startEmpty: return "Start Empty"
        case .showInFinder: return "Show in Finder"
        }
    }

    static func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

#if VOICE_FLOW_QA
    func qaChoose(_ action: String) -> Bool {
        let wanted: (ThreadStoreRecovery.Choice) -> Bool = { choice in
            switch (action, choice) {
            case ("restore", .restoreBackup), ("repair", .repair), ("empty", .startEmpty): return true
            default: return false
            }
        }
        guard let index = choices.firstIndex(where: wanted), buttons[index].isEnabled else { return false }
        buttons[index].performClick(nil)
        return true
    }

    func qaSnapshot(at url: URL) throws {
        guard let content = window?.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw NSError(domain: "ThreadStoreRecoveryWindow", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recovery window is not visible."])
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url, options: .atomic)
    }
#endif
}
