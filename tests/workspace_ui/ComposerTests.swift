import Cocoa

private func composerViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(composerViews)
}

private final class ComposerDataSource: WorkspaceEditorDataSource {
    var details: [AgentsThreadID: AgentThreadDetail] = [:]
    var rejectSend = false
    override func agentThreadDetail(for id: AgentsThreadID) -> AgentThreadDetail? { details[id] }
    override func sendMessage(toThread id: AgentsThreadID, text: String, attachments: [String]) throws {
        if rejectSend { throw NSError(domain: "Send fixture rejected", code: 1) }
        try super.sendMessage(toThread: id, text: text, attachments: attachments)
    }
}

func runComposerTests() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let composer = ComposerView(placeholder: "Message FLORA…")
    window.contentView!.addSubview(composer)
    composer.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        composer.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
        composer.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
        composer.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
    ])
    composer.setControls(ComposerControls(accessOptions: ["Full access"], attach: true, mic: true, snap: true,
        runtimeOptions: ["Claude Code"], modelOptions: ["Anthropic: Claude Opus 4.6 (Extended Thinking)"],
        effortOptions: ["Extra high"]))
    expect(!composer.sendControl.isEnabled, "empty composer must present a disabled Send")
    composer.text = " \n "
    expect(!composer.sendControl.isEnabled, "whitespace-only message must not enable Send")
    composer.addAttachment(path: "/tmp/composer-fixture.png")
    expect(composer.sendControl.isEnabled, "an image-only message must enable Send")
    composer.clear()
    expect(!composer.sendControl.isEnabled, "clearing a message must disable Send")
    composer.text = "👩🏽‍💻 hello"
    composer.focus()
    let editor = composerViews(composer).compactMap { $0 as? NSTextView }.first!
    expect(editor.selectedRange().location == composer.text.utf16.count,
           "focus must put the caret after the complete Unicode draft")
    var sends = 0
    composer.onSend = { _, _ in sends += 1 }
    composer.setStatus("Working on the requested changes", running: true)
    _ = composer.textView(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
    expect(sends == 0 && composer.text == "👩🏽‍💻 hello", "Return during a turn must preserve the queued draft")

    for width: CGFloat in [900, 700, 520, 420, 900] {
        window.setContentSize(NSSize(width: width, height: 540))
        window.layoutIfNeeded()
        let status = composerViews(composer).compactMap { $0 as? NSTextField }.first { $0.stringValue == composer.status }!
        expect(composer.accessControl!.bounds.width >= composer.accessControl!.intrinsicContentSize.width - 1,
               "access mode must remain fully readable at width \(width)")
        expect(status.bounds.width >= 100, "running activity became unreadable at width \(width)")
        expect(composer.modelControl!.bounds.width >= 100, "model control became unreadable at width \(width)")
        let stop = composer.convert(composer.stopControl.bounds, from: composer.stopControl)
        expect(stop.minX >= 0 && stop.maxX <= width && stop.width >= 24, "Stop must remain reachable at width \(width)")
        composer.attachments = (1...15).map { "/tmp/composer-fixture-\($0).png" }
        window.layoutIfNeeded()
        expect(abs(composer.bounds.width - width) < 1, "attachments must never widen the panel")
        let chip = composerViews(composer).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Remove attached image 15" }!
        let attachmentScroll = chip.enclosingScrollView!
        chip.scrollToVisible(chip.bounds)
        window.layoutIfNeeded()
        expect(chip.visibleRect.width >= 40, "last attachment must be reachable through horizontal scrolling")
        expect(attachmentScroll.bounds.width <= width, "attachment viewport must remain bounded")
        chip.performClick(nil)
        expect(composer.attachments.count == 14, "scrolled attachment must remain removable")
        saveUIPreview(composer, name: "composer-\(Int(width))")
    }

    let source = ComposerDataSource()
    let first = AgentsThreadID(source: .mcp, value: "composer-first")
    let second = AgentsThreadID(source: .mcp, value: "composer-second")
    for id in [first, second] {
        source.details[id] = AgentThreadDetail(id: id, title: id.value, owner: "Fixture", state: "Live",
            messages: [], archived: false, live: true, pendingAsk: false, canReply: true,
            canSpeak: false, canComplete: false, canDelete: false, claimsContextualFocus: true,
            readOnlyReason: nil, linkedAutomationCount: 0)
    }
    let view = AgentsView(frame: NSRect(x: 0, y: 0, width: 720, height: 540))
    view.dataSource = source
    window.contentView = view
    view.openThread(first)
    func currentComposer() -> ComposerView { composerViews(view).compactMap { $0 as? ComposerView }.first! }
    let firstComposer = currentComposer()
    firstComposer.text = "Original draft"
    firstComposer.focus()
    let firstEditor = composerViews(firstComposer).compactMap { $0 as? NSTextView }.first!
    firstEditor.insertText(" revised", replacementRange: NSRange(location: firstEditor.string.utf16.count, length: 0))
    firstEditor.setSelectedRange(NSRange(location: 2, length: 4))
    expect(firstEditor.undoManager?.canUndo == true, "fixture must establish an undoable edit")
    view.refresh()
    expect(currentComposer() === firstComposer, "same-thread refresh must retain the live editor")
    expect(window.firstResponder === firstEditor && firstEditor.selectedRange() == NSRange(location: 2, length: 4),
           "same-thread refresh must retain focus and selection")
    firstEditor.undoManager?.undo()
    expect(firstComposer.text == "Original draft", "same-thread refresh must preserve the undo history")
    source.rejectSend = true
    firstComposer.text = "  Retry this draft  "
    firstEditor.setSelectedRange(NSRange(location: 3, length: 5))
    firstComposer.sendControl.performClick(nil)
    expect(currentComposer() === firstComposer && firstComposer.text == "  Retry this draft  ",
           "failed send must preserve the exact editor and untrimmed draft")
    expect(firstEditor.selectedRange() == NSRange(location: 3, length: 5), "failed send must preserve selection")
    view.openThread(second)
    currentComposer().text = "Second thread draft"
    view.acceptPickedAttachments(["/tmp/original-thread.png"], for: first)
    expect(currentComposer().attachments.isEmpty && currentComposer().text == "Second thread draft",
           "a delayed picker must never attach files to the newly opened thread")
    view.openThread(first)
    expect(currentComposer().attachments == ["/tmp/original-thread.png"], "picker result must survive in its original thread")
    expect(currentComposer().text == "  Retry this draft  ", "thread navigation must restore its own draft")
    source.details[first] = nil
    view.refresh()
    expect(composerViews(view).compactMap { $0 as? ComposerView }.isEmpty, "deleted thread must remove the retained composer")
    print("PASS: composer drafts, undo, selection, attachment routing and responsive controls")
}
