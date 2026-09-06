import Cocoa

private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
}

func runRowAccessibilityTests() {
    let view = AgentsView(frame: NSRect(x: 0, y: 0, width: 720, height: 540))
    let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.contentView = view

    func creationRow() -> NSView {
        view.showWorkspaceRoot(.assistants)
        view.layoutSubtreeIfNeeded()
        let row = descendants(of: view).first {
            $0.accessibilityRole() == .button && $0.accessibilityLabel() == "New assistant"
        }
        expect(row != nil, "each agent row must expose an individually labeled accessibility button")
        return row!
    }

    let accessible = creationRow()
    expect(accessible.accessibilityChildren()?.isEmpty == true,
           "decorative row labels must not duplicate the accessible action")
    expect(accessible.accessibilityPerformPress(), "accessible Press must activate the row")
    expect(view.qaNavigationState["mode"] as? String == "assistant_create",
           "accessible Press must open the same destination as a mouse click")

    for (characters, code) in [("\r", UInt16(36)), (" ", UInt16(49))] {
        let row = creationRow()
        expect(row.acceptsFirstResponder && row.canBecomeKeyView,
               "agent rows must be reachable through keyboard focus")
        expect(window.makeFirstResponder(row), "agent row refused keyboard focus")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: 0, windowNumber: window.windowNumber,
                                    context: nil, characters: characters,
                                    charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        row.keyDown(with: event)
        expect(view.qaNavigationState["mode"] as? String == "assistant_create",
               "Return and Space must activate the focused agent row")
    }

    let source = WorkspaceEditorDataSource()
    source.jobs = [AgentJobRow(
        id: "history", name: "History fixture", preview: "Ready", time: "", updatedAt: Date(),
        assistantName: "FLORA", assistantSlug: "flora", state: .completed,
        isEnabled: true, runtime: .codex, trigger: .manual, modelID: nil,
        prompt: "Fixture", nextRunAt: nil, intervalSeconds: nil, dailyTimeMinutes: nil,
        dailyBudgetUSD: 1, spentTodayUSD: 0, maxDurationSeconds: 60, maxAttempts: 1,
        hasPendingTrigger: false,
        runs: [AgentRunRow(id: "run", state: .completed, startedAt: Date(),
                           finishedAt: Date(), attempt: 1, costUSD: 0, error: nil)])]
    view.dataSource = source
    _ = view.qaNavigate(destination: "automations", automationAction: nil, jobID: "history",
                        threadSource: nil, threadID: nil, threadFilter: nil)
    let history = descendants(of: view).first {
        $0.accessibilityRole() == .group && $0.accessibilityLabel() == "Completed"
    }
    expect(history != nil && history?.acceptsFirstResponder == false,
           "read-only run history must not become an inert keyboard button")
    expect(history?.accessibilityPerformPress() == false,
           "read-only run history must not advertise an activation")
    expect(history?.isAccessibilitySelectorAllowed(NSSelectorFromString("accessibilityPerformPress")) == false,
           "read-only run history must not advertise a Press action to assistive tools")
}
