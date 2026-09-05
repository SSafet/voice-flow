import Cocoa

// Run with the app support sources (all swift/*.swift except main.swift).
// No AppDelegate/backend, user data, event synthesis, or external app is needed.
func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func settle() {
    let deadline = Date().addingTimeInterval(0.3)
    while Date() < deadline {
        if let event = NSApp.nextEvent(matching: .any, until: deadline,
                                      inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.main.async {
    let workspace = ChatPanel()
    let window = app.windows.first { $0 is KeyablePanel }!

    workspace.show(focusInput: false)
    settle()
    expect(workspace.isVisible, "Passive workspace open must remain visible")
    expect(!window.isKeyWindow, "Passive workspace open must not take keyboard focus")

    workspace.show()
    settle()
    expect(window.isKeyWindow, "Explicit workspace open must accept keyboard input")

    // The same hide path is called by the global outside-click monitor.
    workspace.hide()
    expect(!workspace.isVisible, "Dismissal must order out synchronously, before the next click")
    expect(!window.isKeyWindow, "Dismissal must immediately release keyboard focus")
    expect(workspace.conversationFocus == .none, "Dismissed workspace must not route captures")

    // Previously the old fade completion hid the newly opened workspace.
    workspace.show()
    settle()
    expect(workspace.isVisible && window.isKeyWindow,
           "Reopening during the old fade interval must keep the workspace visible and key")

    workspace.hide()
    workspace.show(focusInput: false)
    settle()
    expect(workspace.isVisible && !window.isKeyWindow,
           "Passive reopen must remain visible without reclaiming keyboard focus")

    // A hidden pane still participates in AppKit layout. Its long labels used
    // to enlarge the entire window even while another destination was visible.
    let expectedFrame = window.frame
    let longLabel = NSTextField(labelWithString: String(repeating: "Long source title ", count: 300))
    longLabel.lineBreakMode = .byTruncatingTail
    workspace.setSourcesView(longLabel)
    settle()
    expect(window.frame == expectedFrame,
           "Hidden pane content must not enlarge or move the workspace")
    workspace.showSources()
    settle()
    expect(window.frame == expectedFrame,
           "Visible pane content must fit inside the positioned workspace")
    workspace.hide()
    let smallDisplay = NSRect(x: -720, y: 0, width: 720, height: 540)
    workspace.panelAnchorProvider = {
        PanelAnchor(frame: NSRect(x: -30, y: 5, width: 52, height: 18),
                    visibleFrame: smallDisplay)
    }
    workspace.show(focusInput: false)
    settle()
    expect(smallDisplay.insetBy(dx: 8, dy: 8).contains(window.frame),
           "Long content must stay inside a smaller display after repositioning")
    workspace.hide()
    print("PASS: passive open, explicit focus, immediate dismissal, capture release, rapid reopen, bounded content")
    exit(0)
}
app.run()
