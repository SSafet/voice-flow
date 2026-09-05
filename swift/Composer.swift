import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Composer — the one place the user types a message to an agent
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Every message input is this view. It grows with the text — one line up
//  to `maxHeight`, then it scrolls — and carries, on a toolbar under the
//  text, everything a turn needs: which runtime answers (Codex, Claude
//  Code, OpenCode), how hard it thinks, what it is doing right now, a snap
//  of the screen, and Send — which becomes Stop while the turn runs.
//  Attached images sit above the text as chips (click to remove).
//
//  The composer never disappears during a turn: the draft you type while
//  the assistant works stays put, Return waits, Stop is one tap away.

/// The controls an assistant thread puts on the toolbar. nil = a plain
/// composer (MCP threads: text, images, Send).
struct ComposerControls: Equatable {
    var runtimeOptions: [String] = []
    var runtimeIndex: Int = 0
    var runtimeEnabled: Bool = true
    var effortOptions: [String] = []
    var effortIndex: Int = 0
    var snap: Bool = false
}

final class ComposerView: NSView {
    /// Fired on Return or send with the trimmed text and the file paths of
    /// any pasted images. Clearing is the caller's call — a send that fails
    /// keeps the draft and its attachments.
    var onSend: ((String, [String]) -> Void)?
    /// Per-keystroke hook, for stashing drafts.
    var onTextChanged: (() -> Void)?
    var onRuntimeSelected: ((Int) -> Void)?
    var onEffortSelected: ((Int) -> Void)?
    var onSnap: (() -> Void)?
    var onStop: (() -> Void)?

    private let textView = ComposerTextView()
    private let attachmentsRow = NSStackView()
    private var attachmentPaths: [String] = []
    private let scroll = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let toolbar = NSStackView()
    private let runtimePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let snapButton = NSButton()
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

    /// The send button, for callers that inspect or restyle it.
    var sendControl: NSButton { sendButton }
    /// The toolbar controls, for QA state and the panel's accessibility list.
    var runtimeControl: NSPopUpButton? { controls?.runtimeOptions.isEmpty == false ? runtimePopUp : nil }
    var effortControl: NSPopUpButton? { controls?.effortOptions.isEmpty == false ? effortPopUp : nil }
    var stopControl: NSButton { stopButton }
    var status: String { statusLabel.stringValue }

    var hasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === textView
    }

    /// - Parameter maxHeight: how far the field grows before it starts scrolling.
    init(placeholder: String, fontSize: CGFloat = 12.5,
         minHeight: CGFloat = 34, maxHeight: CGFloat = 132,
         inset: CGFloat = 8) {
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.inset = inset
        super.init(frame: .zero)

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
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10).cgColor
        scroll.layer?.cornerRadius = 8

        placeholderLabel.stringValue = placeholder
        placeholderLabel.font = font
        placeholderLabel.textColor = Theme.text3
        placeholderLabel.lineBreakMode = .byTruncatingTail

        // Toolbar ---------------------------------------------------------
        for popUp in [runtimePopUp, effortPopUp] {
            popUp.controlSize = .mini
            popUp.font = .systemFont(ofSize: 10, weight: .medium)
            popUp.target = self
            popUp.isHidden = true
        }
        runtimePopUp.action = #selector(runtimeChanged)
        runtimePopUp.toolTip = "Runtime for this conversation"
        runtimePopUp.setAccessibilityLabel("Assistant runtime")
        effortPopUp.action = #selector(effortChanged)
        effortPopUp.toolTip = "How hard the model thinks"
        effortPopUp.setAccessibilityLabel("Reasoning effort")

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = Theme.accent
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        snapButton.image = NSImage(systemSymbolName: "camera.viewfinder",
                                   accessibilityDescription: "Snap the screen and send") ?? NSImage()
        snapButton.isBordered = false
        snapButton.title = ""
        snapButton.contentTintColor = Theme.text2
        snapButton.target = self
        snapButton.action = #selector(snapTapped)
        snapButton.toolTip = "Snap the screen and send"
        snapButton.setAccessibilityLabel("Snap the screen and send")
        snapButton.isHidden = true

        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill",
                                   accessibilityDescription: "Send") ?? NSImage()
        sendButton.isBordered = false
        sendButton.title = ""
        sendButton.contentTintColor = Theme.accent
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.setAccessibilityLabel("Send")
        sendButton.toolTip = "Send"

        stopButton.image = NSImage(systemSymbolName: "stop.circle.fill",
                                   accessibilityDescription: "Stop") ?? NSImage()
        stopButton.isBordered = false
        stopButton.title = ""
        stopButton.contentTintColor = NSColor(r: 255, g: 110, b: 100)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.setAccessibilityLabel("Stop the assistant")
        stopButton.toolTip = "Stop this turn"
        stopButton.isHidden = true

        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        for view in [runtimePopUp, effortPopUp, statusLabel, snapButton, sendButton, stopButton] {
            toolbar.addArrangedSubview(view)
        }

        attachmentsRow.orientation = .horizontal
        attachmentsRow.spacing = 6
        attachmentsRow.isHidden = true
        attachmentsRow.setAccessibilityLabel("Attached images")

        for view in [scroll, placeholderLabel, attachmentsRow, toolbar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: minHeight)
        attachmentsHeight = attachmentsRow.heightAnchor.constraint(equalToConstant: 0)
        attachmentsGap = scroll.topAnchor.constraint(equalTo: attachmentsRow.bottomAnchor,
                                                     constant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            attachmentsHeight,
            attachmentsGap,
            attachmentsRow.topAnchor.constraint(equalTo: topAnchor),
            attachmentsRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            attachmentsRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 24),
            toolbar.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor,
                                                      constant: inset),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor,
                                                       constant: -inset),
            placeholderLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: inset),
        ])
        syncPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

    // ── Toolbar state ───────────────────────────────────

    /// Which runtime/effort/snap controls to show; nil hides them all.
    func setControls(_ value: ComposerControls?) {
        controls = value
        let controls = value ?? ComposerControls()
        runtimePopUp.removeAllItems()
        runtimePopUp.addItems(withTitles: controls.runtimeOptions)
        runtimePopUp.isHidden = controls.runtimeOptions.isEmpty
        if controls.runtimeOptions.indices.contains(controls.runtimeIndex) {
            runtimePopUp.selectItem(at: controls.runtimeIndex)
        }
        effortPopUp.removeAllItems()
        effortPopUp.addItems(withTitles: controls.effortOptions)
        effortPopUp.isHidden = controls.effortOptions.isEmpty
        if controls.effortOptions.indices.contains(controls.effortIndex) {
            effortPopUp.selectItem(at: controls.effortIndex)
        }
        snapButton.isHidden = !controls.snap
        applyRunningState()
    }

    /// What the turn is doing, and whether one is running (Send ↔ Stop).
    func setStatus(_ text: String?, running: Bool) {
        statusLabel.stringValue = text ?? ""
        isRunning = running
        applyRunningState()
    }

    private func applyRunningState() {
        let controls = controls ?? ComposerControls()
        runtimePopUp.isEnabled = controls.runtimeEnabled && !isRunning
        snapButton.isEnabled = !isRunning
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
    @objc private func runtimeChanged() { onRuntimeSelected?(runtimePopUp.indexOfSelectedItem) }
    @objc private func effortChanged() { onEffortSelected?(effortPopUp.indexOfSelectedItem) }

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
