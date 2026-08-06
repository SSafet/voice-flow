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
    /// Fired with the trimmed text on Return or send. Clearing is the
    /// caller's call — a send that fails keeps the draft.
    var onSend: ((String) -> Void)?
    /// Per-keystroke hook, for stashing drafts.
    var onTextChanged: (() -> Void)?

    private let textView = ComposerTextView()
    private let scroll = NSScrollView()
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton()
    private var heightConstraint: NSLayoutConstraint!
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
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

        var views: [NSView] = [scroll, placeholderLabel, sendButton]
        if let leading { views.append(leading) }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: minHeight)
        var constraints: [NSLayoutConstraint] = [
            heightConstraint,
            scroll.topAnchor.constraint(equalTo: topAnchor),
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
        guard !value.isEmpty else { return }
        onSend?(value)
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
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }
}
