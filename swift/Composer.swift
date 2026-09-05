import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Composer — the one place the user types a message to an agent
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Modeled on the session bars of Claude Code and Codex: one bordered box,
//  pinned to the bottom of the thread, with everything about the session
//  around the text. Bottom-left is what the agent may do here — access
//  mode, attach an image, dictate, snap the screen. Bottom-right is what
//  answers — runtime, reasoning effort — plus the live status with a
//  spinner, and Send, which becomes Stop while the turn runs.
//
//  The box never disappears during a turn: the draft you type while the
//  assistant works stays put, Return waits, Stop is one tap away. Attached
//  images sit above the text as chips (click to remove).

/// The controls an assistant thread puts on the bar. nil = a plain
/// composer (MCP threads: text, images, Send).
struct ComposerControls: Equatable {
    var accessOptions: [String] = []
    var accessIndex: Int = 0
    var accessEnabled: Bool = true
    var attach: Bool = false
    var mic: Bool = false
    var snap: Bool = false
    var runtimeOptions: [String] = []
    var runtimeIndex: Int = 0
    var runtimeEnabled: Bool = true
    var modelOptions: [String] = []
    var modelIndex: Int = 0
    var effortOptions: [String] = []
    var effortIndex: Int = 0
}

final class ComposerView: NSView {
    /// Fired on Return or send with the trimmed text and the file paths of
    /// any attached images. Clearing is the caller's call — a send that
    /// fails keeps the draft and its attachments.
    var onSend: ((String, [String]) -> Void)?
    /// Per-keystroke hook, for stashing drafts.
    var onTextChanged: (() -> Void)?
    var onAccessSelected: ((Int) -> Void)?
    var onRuntimeSelected: ((Int) -> Void)?
    var onModelSelected: ((Int) -> Void)?
    var onEffortSelected: ((Int) -> Void)?
    var onMicToggle: (() -> Void)?
    /// The + button; the owner presents the picker and adds what was chosen.
    var onAttachRequested: (() -> Void)?
    var onSnap: (() -> Void)?
    var onStop: (() -> Void)?

    private let box = NSView()
    private let textView = ComposerTextView()
    private let attachmentsRow = NSStackView()
    private var attachmentPaths: [String] = []
    private let scroll = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let bar = NSStackView()
    private let accessPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let attachButton = NSButton()
    private let micButton = NSButton()
    private let snapButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let runtimePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sendButton = NSButton()
    private let stopButton = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private var attachmentsHeight: NSLayoutConstraint!
    private var attachmentsGap: NSLayoutConstraint!
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let inset: CGFloat
    private var controls: ComposerControls?
    private(set) var isRunning = false
    private(set) var isRecording = false

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            syncPlaceholder()
            updateHeight()
        }
    }

    var placeholder: String {
        get { placeholderLabel.stringValue }
        set { placeholderLabel.stringValue = newValue }
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachmentPaths.isEmpty
    }

    /// Attached image paths — stashed and restored across rebuilds by the owner.
    var attachments: [String] {
        get { attachmentPaths }
        set {
            attachmentPaths = newValue
            rebuildAttachments()
        }
    }

    /// The bar's controls, for QA state and the panel's accessibility list.
    var sendControl: NSButton { sendButton }
    var stopControl: NSButton { stopButton }
    var micControl: NSButton? { controls?.mic == true ? micButton : nil }
    var accessControl: NSPopUpButton? { controls?.accessOptions.isEmpty == false ? accessPopUp : nil }
    var runtimeControl: NSPopUpButton? { controls?.runtimeOptions.isEmpty == false ? runtimePopUp : nil }
    var modelControl: NSPopUpButton? { controls?.modelOptions.isEmpty == false ? modelPopUp : nil }
    var effortControl: NSPopUpButton? { controls?.effortOptions.isEmpty == false ? effortPopUp : nil }
    var status: String { statusLabel.stringValue }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === textView
    }

    /// - Parameter maxHeight: how far the text grows before it starts scrolling.
    init(placeholder: String, fontSize: CGFloat = 13,
         minHeight: CGFloat = 44, maxHeight: CGFloat = 150,
         inset: CGFloat = 10) {
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.inset = inset
        super.init(frame: .zero)

        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 8).cgColor
        box.layer?.borderColor = Theme.borderHover.cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 12

        let font = NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.text
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: inset, height: inset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.setAccessibilityLabel("Message composer")

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        placeholderLabel.stringValue = placeholder
        placeholderLabel.font = font
        placeholderLabel.textColor = Theme.text3
        placeholderLabel.lineBreakMode = .byTruncatingTail

        // The bar --------------------------------------------------------
        for popUp in [accessPopUp, runtimePopUp, modelPopUp, effortPopUp] {
            popUp.isBordered = false
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: 11.5, weight: .medium)
            popUp.contentTintColor = Theme.text2
            popUp.target = self
            popUp.isHidden = true
            // Long OpenRouter names must truncate, never push Send off the bar.
            popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            popUp.lineBreakMode = .byTruncatingTail
            popUp.translatesAutoresizingMaskIntoConstraints = false
            popUp.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        }
        accessPopUp.action = #selector(accessChanged)
        accessPopUp.toolTip = "What the assistant may do on this Mac"
        accessPopUp.setAccessibilityLabel("Access mode")
        runtimePopUp.action = #selector(runtimeChanged)
        runtimePopUp.toolTip = "Runtime for this conversation"
        runtimePopUp.setAccessibilityLabel("Assistant runtime")
        modelPopUp.action = #selector(modelChanged)
        modelPopUp.toolTip = "Model for this runtime"
        modelPopUp.setAccessibilityLabel("Model")
        effortPopUp.action = #selector(effortChanged)
        effortPopUp.toolTip = "How hard the model thinks"
        effortPopUp.setAccessibilityLabel("Reasoning effort")

        configureIcon(attachButton, "plus", label: "Attach an image", action: #selector(attachTapped))
        configureIcon(micButton, "mic", label: "Dictate into this thread", action: #selector(micTapped))
        configureIcon(snapButton, "camera.viewfinder", label: "Snap the screen and send", action: #selector(snapTapped))
        attachButton.isHidden = true
        micButton.isHidden = true
        snapButton.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setAccessibilityLabel("Working")

        statusLabel.font = .systemFont(ofSize: 11.5)
        statusLabel.textColor = Theme.accent
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.isHidden = true

        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill",
                                   accessibilityDescription: "Send") ?? NSImage()
        sendButton.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        sendButton.isBordered = false
        sendButton.title = ""
        sendButton.contentTintColor = Theme.accent
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.setAccessibilityLabel("Send")
        sendButton.toolTip = "Send (Return)"

        stopButton.image = NSImage(systemSymbolName: "stop.circle.fill",
                                   accessibilityDescription: "Stop") ?? NSImage()
        stopButton.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        stopButton.isBordered = false
        stopButton.title = ""
        stopButton.contentTintColor = NSColor(r: 255, g: 110, b: 100)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.setAccessibilityLabel("Stop the assistant")
        stopButton.toolTip = "Stop this turn"
        stopButton.isHidden = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for view in [accessPopUp, attachButton, micButton, snapButton, spacer,
                     spinner, statusLabel, runtimePopUp, modelPopUp, effortPopUp, sendButton, stopButton] {
            bar.addArrangedSubview(view)
        }

        attachmentsRow.orientation = .horizontal
        attachmentsRow.spacing = 6
        attachmentsRow.isHidden = true
        attachmentsRow.setAccessibilityLabel("Attached images")

        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        for view in [attachmentsRow, scroll, placeholderLabel, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(view)
        }

        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: minHeight)
        attachmentsHeight = attachmentsRow.heightAnchor.constraint(equalToConstant: 0)
        attachmentsGap = scroll.topAnchor.constraint(equalTo: attachmentsRow.bottomAnchor, constant: 0)
        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightConstraint,
            attachmentsHeight,
            attachmentsGap,
            attachmentsRow.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            attachmentsRow.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            attachmentsRow.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -inset),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -2),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 2),
            bar.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 34),
            bar.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            placeholderLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: inset),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -inset),
            placeholderLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: inset),
        ])
        syncPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureIcon(_ button: NSButton, _ symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        button.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        button.isBordered = false
        button.title = ""
        button.contentTintColor = Theme.text2
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    // ── Bar state ───────────────────────────────────────

    /// Which controls to show; nil hides the session controls.
    func setControls(_ value: ComposerControls?) {
        controls = value
        let controls = value ?? ComposerControls()
        fill(accessPopUp, controls.accessOptions, controls.accessIndex)
        fill(runtimePopUp, controls.runtimeOptions, controls.runtimeIndex)
        fill(modelPopUp, controls.modelOptions, controls.modelIndex)
        fill(effortPopUp, controls.effortOptions, controls.effortIndex)
        attachButton.isHidden = !controls.attach
        micButton.isHidden = !controls.mic
        snapButton.isHidden = !controls.snap
        applyRunningState()
    }

    private func fill(_ popUp: NSPopUpButton, _ options: [String], _ index: Int) {
        popUp.removeAllItems()
        popUp.addItems(withTitles: options)
        popUp.isHidden = options.isEmpty
        if options.indices.contains(index) { popUp.selectItem(at: index) }
        if popUp === accessPopUp {
            // Full access reads as a warning, the way the reference bars do:
            // a pop-up draws the selected item's own title, so colour lives
            // on the item.
            for item in popUp.itemArray where item.title.lowercased().contains("full") {
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [
                    .foregroundColor: NSColor(r: 240, g: 140, b: 60),
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                ])
            }
        }
    }

    /// What the turn is doing, and whether one is running (Send ↔ Stop).
    func setStatus(_ text: String?, running: Bool) {
        statusLabel.stringValue = text ?? ""
        isRunning = running
        applyRunningState()
    }

    /// A dictation is going into this thread.
    func setRecording(_ on: Bool) {
        isRecording = on
        micButton.image = NSImage(systemSymbolName: on ? "mic.fill" : "mic",
                                  accessibilityDescription: on ? "Stop dictating" : "Dictate into this thread") ?? NSImage()
        micButton.contentTintColor = on ? NSColor(r: 255, g: 110, b: 100) : Theme.text2
        micButton.toolTip = on ? "Stop dictating" : "Dictate into this thread"
        micButton.setAccessibilityLabel(on ? "Stop dictating" : "Dictate into this thread")
    }

    private func applyRunningState() {
        let controls = controls ?? ComposerControls()
        accessPopUp.isEnabled = controls.accessEnabled && !isRunning
        runtimePopUp.isEnabled = controls.runtimeEnabled && !isRunning
        modelPopUp.isEnabled = !isRunning
        snapButton.isEnabled = !isRunning
        micButton.isEnabled = !isRunning
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
        spinner.isHidden = !isRunning
        if isRunning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        sendButton.isHidden = isRunning
        stopButton.isHidden = !isRunning
    }

    func focus() {
        window?.layoutIfNeeded()
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
    }

    override func layout() {
        super.layout()
        // Wrapping — and so the height — depends on the field's width, which
        // is only known once the panel has laid out.
        updateHeight()
    }

    @objc private func sendTapped() { submit() }
    @objc private func stopTapped() { onStop?() }
    @objc private func snapTapped() { onSnap?() }
    @objc private func micTapped() { onMicToggle?() }
    @objc private func accessChanged() {
        applyRunningState()
        onAccessSelected?(accessPopUp.indexOfSelectedItem)
    }
    @objc private func runtimeChanged() { onRuntimeSelected?(runtimePopUp.indexOfSelectedItem) }
    @objc private func modelChanged() { onModelSelected?(modelPopUp.indexOfSelectedItem) }

    /// Pick a model item the way a click would (QA drives the real path).
    func selectModel(at index: Int) -> Bool {
        guard modelPopUp.itemArray.indices.contains(index) else { return false }
        modelPopUp.selectItem(at: index)
        modelChanged()
        return true
    }
    @objc private func effortChanged() { onEffortSelected?(effortPopUp.indexOfSelectedItem) }

    /// The + button: the owner presents a non-modal picker.
    @objc private func attachTapped() { onAttachRequested?() }

    func addAttachment(path: String) {
        attachmentPaths.append(path)
        rebuildAttachments()
    }

    private func submit() {
        // While a turn runs the draft waits; Stop is the only action.
        guard !isRunning else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // An image on its own is a message; text is not required.
        guard !value.isEmpty || !attachmentPaths.isEmpty else { return }
        onSend?(value, attachmentPaths)
    }

    /// Empty the composer after a send the caller accepted.
    func clear() {
        text = ""
        attachmentPaths = []
        rebuildAttachments()
    }

    // ── Pasted images ───────────────────────────────────

    /// Called by the text view before it pastes. Returns true when the
    /// pasteboard held images and we consumed them instead.
    fileprivate func consumePastedImages() -> Bool {
        let pasteboard = NSPasteboard.general
        // Text wins whenever it is on offer: copying from a rich editor puts
        // BOTH a string and a rendered image on the pasteboard, and the user
        // pressing ⌘V there means the words.
        if pasteboard.canReadObject(forClasses: [NSString.self], options: nil) { return false }
        guard let images = pasteboard.readObjects(forClasses: [NSImage.self],
                                                  options: nil) as? [NSImage],
              !images.isEmpty else { return false }

        var added = false
        for image in images {
            // Prefer the pasteboard's own bytes; fall back to re-encoding the
            // NSImage when the type is one CoreGraphics gave us indirectly.
            let raw = pasteboard.data(forType: .png)
                ?? pasteboard.data(forType: .tiff)
                ?? image.tiffRepresentation
            guard let raw, let path = CaptureStore.savePastedImage(raw) else {
                vflog("composer: could not save a pasted image")
                continue
            }
            attachmentPaths.append(path)
            added = true
        }
        guard added else { return false }
        rebuildAttachments()
        return true
    }

    private func rebuildAttachments() {
        for view in attachmentsRow.arrangedSubviews {
            attachmentsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, path) in attachmentPaths.enumerated() {
            let chip = NSButton()
            chip.image = NSImage(contentsOfFile: path)
            chip.imageScaling = .scaleProportionallyUpOrDown
            chip.isBordered = false
            chip.title = ""
            chip.tag = index
            chip.target = self
            chip.action = #selector(attachmentTapped(_:))
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 5
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = Theme.border.cgColor
            chip.layer?.masksToBounds = true
            chip.toolTip = "Click to remove — \((path as NSString).lastPathComponent)"
            chip.setAccessibilityLabel("Remove attached image \(index + 1)")
            chip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                chip.widthAnchor.constraint(equalToConstant: 46),
                chip.heightAnchor.constraint(equalToConstant: 32),
            ])
            attachmentsRow.addArrangedSubview(chip)
        }
        let showing = !attachmentPaths.isEmpty
        attachmentsRow.isHidden = !showing
        attachmentsHeight.constant = showing ? 32 : 0
        attachmentsGap.constant = showing ? 6 : 0
    }

    @objc private func attachmentTapped(_ sender: NSButton) {
        guard attachmentPaths.indices.contains(sender.tag) else { return }
        attachmentPaths.remove(at: sender.tag)
        rebuildAttachments()
    }

    private func syncPlaceholder() {
        placeholderLabel.isHidden = !textView.string.isEmpty
    }

    private func updateHeight() {
        guard let manager = textView.layoutManager,
              let container = textView.textContainer else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height + inset * 2
        let target = min(max(used, minHeight), maxHeight)
        guard abs(heightConstraint.constant - target) > 0.5 else { return }
        heightConstraint.constant = target
        // At the cap the field scrolls instead of growing; keep the caret visible.
        if target >= maxHeight { textView.scrollRangeToVisible(textView.selectedRange()) }
    }
}

extension ComposerView: NSTextViewDelegate {
    /// Return sends; ⌥Return and ⇧Return insert a newline.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.option) || flags.contains(.shift) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        submit()
        return true
    }

    func textDidChange(_ notification: Notification) {
        syncPlaceholder()
        updateHeight()
        onTextChanged?()
    }
}

/// NSTextView eats Escape (it means "cancel completion"), but in this app
/// Escape is the panic button — it has to reach the panel.
private final class ComposerTextView: NSTextView {
    /// An image on the pasteboard becomes an attachment instead of being
    /// dropped on the floor (this view is plain-text, so AppKit would paste
    /// nothing at all).
    override func paste(_ sender: Any?) {
        if (enclosingComposer?.consumePastedImages() ?? false) { return }
        super.paste(sender)
    }

    private var enclosingComposer: ComposerView? {
        var view: NSView? = superview
        while let current = view {
            if let composer = current as? ComposerView { return composer }
            view = current.superview
        }
        return nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }
}
