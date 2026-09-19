import AppKit

/// The native window that shows a damaged store's reason, the date of the
/// backup it can restore, and one button per choice, in the order `choices`
/// gave (06 §3.2 "Damage is surfaced and recoverable").
///
/// It holds no logic of its own: every button calls back with its `Choice`, and
/// the one static below is the Finder reveal the recovery path needs, kept here
/// because this is the only file in V1 that may import AppKit.
final class ThreadStoreRecoveryWindow: NSObject {
    private let report: DamageReport
    private let choices: [ThreadStoreRecovery.Choice]
    private let onChoice: (ThreadStoreRecovery.Choice) -> Void
    private var window: NSWindow?

    init(report: DamageReport, choices: [ThreadStoreRecovery.Choice],
         onChoice: @escaping (ThreadStoreRecovery.Choice) -> Void) {
        self.report = report
        self.choices = choices
        self.onChoice = onChoice
    }

    func show() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Voice Flow could not open its thread store"

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))

        let reason = NSTextField(wrappingLabelWithString: report.reason)
        reason.frame = NSRect(x: 24, y: 200, width: 512, height: 76)
        content.addSubview(reason)

        if let backup = report.newestBackup {
            let label = NSTextField(labelWithString: backupLine(backup))
            label.frame = NSRect(x: 24, y: 168, width: 512, height: 22)
            content.addSubview(label)
        }

        let width: CGFloat = 160
        for (index, choice) in choices.enumerated() {
            let button = NSButton(title: Self.title(for: choice), target: self,
                                  action: #selector(choose(_:)))
            button.tag = index
            button.frame = NSRect(x: 24 + CGFloat(index % 3) * (width + 12),
                                  y: 60 + CGFloat(index / 3) * 44,
                                  width: width, height: 32)
            content.addSubview(button)
        }

        window.contentView = content
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    @objc private func choose(_ sender: NSButton) {
        guard choices.indices.contains(sender.tag) else { return }
        onChoice(choices[sender.tag])
    }

    private func backupLine(_ backup: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: backup.path)
        if let date = attributes?[.creationDate] as? Date {
            return "Newest backup: \(backup.lastPathComponent), \(date.formatted())"
        }
        return "Newest backup: \(backup.lastPathComponent)"
    }

    private static func title(for choice: ThreadStoreRecovery.Choice) -> String {
        switch choice {
        case .restoreBackup: return "Restore Newest Backup"
        case .repair: return "Try Repair"
        case .startEmpty: return "Start Empty"
        case .showInFinder: return "Show in Finder"
        }
    }

    /// The reveal the recovery path uses for its `.showInFinder` choice.
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
