import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Composer — the one place the user types a message to an agent
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Every message input is this view: the Agents thread composer and the
//  assistant surface's input row. Both were separately-built single-line
//  NSTextFields pinned to a fixed height, so a pasted paragraph became a
//  one-line slit you had to scroll blind. This grows with the text — one
//  line up to `maxHeight`, then it scrolls — and keeps Return/⌥Return,
//  the send button, and the draft plumbing in one place.
//
//  Layout matches what both callers already drew: an optional leading
//  accessory (the snap button), the rounded text area, then send. The
//  buttons sit low so they stay beside the last line as the field grows.

final class ComposerView: NSView {
    /// Fired on Return or send with the trimmed text and the file paths of
    /// any pasted images. Clearing is the caller's call — a send that fails
    /// keeps the draft and its attachments.
    var onSend: ((String, [String]) -> Void)?
    /// Per-keystroke hook, for stashing drafts.
    var onTextChanged: (() -> Void)?

    private let textView = ComposerTextView()
    private let attachmentsRow = NSStackView()
    private var attachmentPaths: [String] = []
    private let scroll = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton()
    private var heightConstraint: NSLayoutConstraint!
    private var attachmentsHeight: NSLayoutConstraint!
    private var attachmentsGap: NSLayoutConstraint!
    private let minHeight: CGFloat
    private let maxHeight: CGFloat
    private let inset: CGFloat

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

    var hasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder === textView
    }

    /// - Parameters:
    ///   - leading: an extra button drawn before the field (the ⌃⌥ snap
    ///     shortcut on the assistant surface); nil elsewhere.
    ///   - maxHeight: how far the field grows before it starts scrolling.
    init(placeholder: String, fontSize: CGFloat = 12.5,
         minHeight: CGFloat = 34, maxHeight: CGFloat = 132,
         inset: CGFloat = 8, leading: NSButton? = nil) {
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

        sendButton.image = NSImage(systemSymbolName: "arrow.up.circle.fill",
                                   accessibilityDescription: "Send") ?? NSImage()
        sendButton.isBordered = false
        sendButton.title = ""
        sendButton.contentTintColor = Theme.accent
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.setAccessibilityLabel("Send")
        sendButton.toolTip = "Send"

        attachmentsRow.orientation = .horizontal
        attachmentsRow.spacing = 6
        attachmentsRow.isHidden = true
        attachmentsRow.setAccessibilityLabel("Attached images")

        var views: [NSView] = [scroll, placeholderLabel, sendButton, attachmentsRow]
        if let leading { views.append(leading) }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: minHeight)
        attachmentsHeight = attachmentsRow.heightAnchor.constraint(equalToConstant: 0)
        attachmentsGap = scroll.topAnchor.constraint(equalTo: attachmentsRow.bottomAnchor,
                                                     constant: 0)
        var constraints: [NSLayoutConstraint] = [
            heightConstraint,
            attachmentsHeight,
            attachmentsGap,
            attachmentsRow.topAnchor.constraint(equalTo: topAnchor),
            attachmentsRow.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            attachmentsRow.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            // Low rather than centered: as the field grows the buttons stay
            // beside the line being typed, not floating in the middle.
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            placeholderLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor,
                                                      constant: inset),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor,
                                                       constant: -inset),
            placeholderLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: inset),
        ]
        if let leading {
            constraints += [
                leading.leadingAnchor.constraint(equalTo: leadingAnchor),
                leading.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
                scroll.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: 8),
            ]
        } else {
            constraints.append(scroll.leadingAnchor.constraint(equalTo: leadingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        syncPlaceholder()
    }

    required init?(coder: NSCoder) { fatalError() }

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

    private func submit() {
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
