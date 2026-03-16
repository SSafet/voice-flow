import Cocoa
import QuartzCore

// ── Colors (warm amber/gold palette — matches Python original) ──

struct Theme {
    static let bg        = NSColor(r: 28, g: 26, b: 24)
    static let bgLighter = NSColor(r: 36, g: 32, b: 24)
    static let text      = NSColor(r: 240, g: 230, b: 214)
    static let text2     = NSColor(r: 176, g: 160, b: 144)
    static let text3     = NSColor(r: 120, g: 104, b: 88)
    static let accent    = NSColor(r: 212, g: 168, b: 83)
    static let accentDim = NSColor(r: 160, g: 120, b: 48)
    static let border    = NSColor(r: 255, g: 220, b: 180, a: 16)
    static let borderHover = NSColor(r: 255, g: 220, b: 180, a: 28)
    static let card      = NSColor(r: 255, g: 245, b: 230, a: 8)
    static let cardHover = NSColor(r: 255, g: 245, b: 230, a: 16)
    static let accentGlow = NSColor(r: 212, g: 168, b: 83, a: 25)

    static func stateColor(_ s: AppState) -> NSColor {
        switch s {
        case .idle:       return text3
        case .loading:    return accent
        case .recording:  return NSColor(r: 220, g: 80, b: 64)
        case .processing: return accent
        case .done:       return NSColor(r: 120, g: 180, b: 100)
        case .handsFree:  return NSColor(r: 230, g: 160, b: 50)
        }
    }
    static func stateLabel(_ s: AppState) -> String {
        switch s {
        case .idle: return "Ready"; case .loading: return "Loading…"
        case .recording: return "Recording"; case .processing: return "Processing…"
        case .done: return "Done"; case .handsFree: return "Hands-Free"
        }
    }
}

extension NSColor {
    convenience init(r: Int, g: Int, b: Int, a: Int = 255) {
        self.init(red: CGFloat(r)/255, green: CGFloat(g)/255,
                  blue: CGFloat(b)/255, alpha: CGFloat(a)/255)
    }
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        var rgb: UInt64 = 0; Scanner(string: h).scanHexInt64(&rgb)
        self.init(r: Int((rgb >> 16) & 0xFF), g: Int((rgb >> 8) & 0xFF), b: Int(rgb & 0xFF))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Menu Bar Manager
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class MenuBarManager: NSObject {
    var onShowHistory: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let btn = statusItem.button {
            let bundle = Bundle.main
            if let imgPath = bundle.path(forResource: "StatusBarIconTemplate@2x", ofType: "png") {
                let img = NSImage(contentsOfFile: imgPath)
                img?.size = NSSize(width: 18, height: 18)
                img?.isTemplate = true
                btn.image = img
            } else {
                btn.title = "🎤"
            }
        }

        let menu = NSMenu()
        statusMenuItem = menu.addItem(withTitle: "Voice Flow — Loading…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show History", action: #selector(historyAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Flow", action: #selector(quitAction), keyEquivalent: "").target = self
        statusItem.menu = menu
    }

    func setState(_ state: AppState) {
        statusMenuItem?.title = "Voice Flow — \(Theme.stateLabel(state))"
    }

    @objc private func historyAction() { onShowHistory?() }
    @objc private func settingsAction() { onShowSettings?() }
    @objc private func quitAction() { onQuit?() }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Floating Indicator (48×22 pill with 3 dots, Core Animation)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class FloatingIndicator: NSObject {
    var onClick: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowHistory: (() -> Void)?

    private let W: CGFloat = 48, H: CGFloat = 22
    private let DOT_R: CGFloat = 3, DOT_SP: CGFloat = 10
    private var panel: NSPanel!
    private var pillLayer: CALayer!
    private var dotLayers: [CALayer] = []
    private var state: AppState = .idle

    func show() {
        let screen = NSScreen.main!.frame
        let x = (screen.width - W) / 2
        let y: CGFloat = 4  // 4px from bottom edge

        panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: W, height: H),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = false

        let rootView = IndicatorView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        rootView.onClick = { [weak self] in self?.onClick?() }
        rootView.onRightClick = { [weak self] view, pt in self?.showContextMenu(in: view, at: pt) }
        rootView.wantsLayer = true
        let root = rootView.layer!

        // Pill background
        pillLayer = CALayer()
        pillLayer.frame = CGRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1)
        pillLayer.cornerRadius = 11.0
        pillLayer.borderWidth = 1.0
        root.addSublayer(pillLayer)

        // Specular highlight
        let spec = CALayer()
        let specH = H * 0.42
        spec.frame = CGRect(x: 1.5, y: H - 1.0 - specH, width: W - 3, height: specH)
        spec.cornerRadius = 10.0
        spec.backgroundColor = NSColor(r: 255, g: 245, b: 230, a: 10).cgColor
        root.addSublayer(spec)

        // 3 dots
        let cy = H / 2.0
        let sx = (W - 2 * DOT_SP) / 2.0
        for i in 0..<3 {
            let dot = CALayer()
            let x = sx + CGFloat(i) * DOT_SP
            dot.frame = CGRect(x: x - DOT_R, y: cy - DOT_R, width: DOT_R * 2, height: DOT_R * 2)
            dot.cornerRadius = DOT_R
            root.addSublayer(dot)
            dotLayers.append(dot)
        }

        panel.contentView = rootView
        panel.orderFront(nil)
        applyState()
    }

    func setState(_ s: AppState) {
        state = s
        applyState()
        if s == .done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if self.state == .done { self.state = .idle; self.applyState() }
            }
        }
    }

    private func applyState() {
        pillLayer?.removeAllAnimations()
        dotLayers.forEach { $0.removeAllAnimations() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        switch state {
        case .recording:
            pillLayer.backgroundColor = NSColor(r: 110, g: 50, b: 45, a: 115).cgColor
            pillLayer.borderColor = NSColor(r: 220, g: 160, b: 140, a: 45).cgColor
            dotLayers.forEach { $0.backgroundColor = NSColor(r: 255, g: 240, b: 220, a: 180).cgColor }
            CATransaction.commit()
            addPulse(duration: 1.45)
            addDotScale(cycle: 2.4)

        case .handsFree:
            pillLayer.backgroundColor = NSColor(r: 100, g: 75, b: 30, a: 120).cgColor
            pillLayer.borderColor = NSColor(r: 230, g: 190, b: 100, a: 50).cgColor
            dotLayers.forEach { $0.backgroundColor = NSColor(r: 255, g: 240, b: 200, a: 190).cgColor }
            CATransaction.commit()
            addPulse(duration: 1.6)
            addDotScale(cycle: 2.8)

        case .processing, .loading:
            pillLayer.backgroundColor = NSColor(r: 100, g: 80, b: 40, a: 110).cgColor
            pillLayer.borderColor = NSColor(r: 212, g: 168, b: 83, a: 45).cgColor
            dotLayers.forEach { $0.backgroundColor = NSColor(r: 255, g: 240, b: 200, a: 170).cgColor }
            CATransaction.commit()
            addPulse(duration: 1.8)
            addDotBounce(cycle: 2.1)

        case .done:
            pillLayer.backgroundColor = NSColor(r: 60, g: 90, b: 50, a: 120).cgColor
            pillLayer.borderColor = NSColor(r: 160, g: 210, b: 140, a: 50).cgColor
            dotLayers.forEach { $0.backgroundColor = NSColor(r: 255, g: 245, b: 220, a: 190).cgColor }
            CATransaction.commit()

        case .idle:
            pillLayer.backgroundColor = NSColor(r: 55, g: 48, b: 40, a: 80).cgColor
            pillLayer.borderColor = NSColor(r: 255, g: 220, b: 180, a: 14).cgColor
            dotLayers.forEach { $0.backgroundColor = NSColor(r: 255, g: 240, b: 220, a: 110).cgColor }
            CATransaction.commit()
        }
    }

    private func addPulse(duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.72; a.toValue = 1.0
        a.duration = duration; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pillLayer.add(a, forKey: "pulse")
    }

    private func addDotScale(cycle: Double) {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        for (i, dot) in dotLayers.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = [1.0, 1.35, 1.0]
            a.keyTimes = [0.0, 0.5, 1.0]
            a.timingFunctions = [ease, ease]
            a.duration = cycle; a.repeatCount = .infinity
            a.timeOffset = Double(2 - i) * cycle / 3.0
            dot.add(a, forKey: "scale")
        }
    }

    private func addDotBounce(cycle: Double) {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let cy = H / 2.0
        for (i, dot) in dotLayers.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "position.y")
            a.values = [cy, cy + 2.5, cy]
            a.keyTimes = [0.0, 0.5, 1.0]
            a.timingFunctions = [ease, ease]
            a.duration = cycle; a.repeatCount = .infinity
            a.timeOffset = Double(2 - i) * cycle / 3.0
            dot.add(a, forKey: "bounce")
        }
    }

    private func showContextMenu(in view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show History", action: #selector(ctxHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Flow", action: #selector(ctxQuit), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: point, in: view)
    }
    @objc private func ctxHistory() { onShowHistory?() }
    @objc private func ctxQuit() { onQuit?() }
}

class IndicatorView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSView, NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(self, convert(event.locationInWindow, from: nil))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  History Window (branded, matches Python AppWindow)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct HistoryEntry {
    let text: String
    let time: String
}

class HistoryWindowController: NSWindowController, NSWindowDelegate {
    var onSettings: (() -> Void)?
    var onWindowClosed: (() -> Void)?
    private var entries: [HistoryEntry] = []
    private var contentStack: NSView!          // flipped document view
    private var bottomConstraint: NSLayoutConstraint?  // last card → bottom
    private var lastCardBottomAnchor: NSLayoutYAxisAnchor?  // chain anchor
    private var emptyView: NSView!
    private var statusPill: NSTextField!
    private var pillContainer: NSView!
    private var scrollView: NSScrollView!
    private var lastDay: String = ""

    init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.minSize = NSSize(width: 420, height: 360)
        w.title = "Voice Flow"
        w.center()
        w.backgroundColor = Theme.bg
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        onWindowClosed?()
        return false  // hide, don't close
    }

    private func setupUI() {
        let content = window!.contentView!
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        // ── header (80px) ───────────────────────────────
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = Theme.bgLighter.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let hStack = NSStackView()
        hStack.orientation = .horizontal
        hStack.spacing = 14
        hStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 16)
        hStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hStack)
        NSLayoutConstraint.activate([
            hStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hStack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            hStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        // Logo
        let bundle = Bundle.main
        if let iconPath = bundle.path(forResource: "icon", ofType: "icns"),
           let img = NSImage(contentsOfFile: iconPath) {
            let iv = NSImageView(image: img)
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 44).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 44).isActive = true
            hStack.addArrangedSubview(iv)
        }

        // Title block
        let titleBlock = NSStackView()
        titleBlock.orientation = .vertical
        titleBlock.alignment = .leading
        titleBlock.spacing = 2
        let titleLabel = NSTextField(labelWithString: "Voice Flow")
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textColor = Theme.accent
        let subtitleLabel = NSTextField(labelWithString: "Local speech-to-text dictation")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = Theme.text3
        titleBlock.addArrangedSubview(titleLabel)
        titleBlock.addArrangedSubview(subtitleLabel)
        hStack.addArrangedSubview(titleBlock)

        // Spacer
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hStack.addArrangedSubview(spacer)

        // Status pill (wrapped in a container for padding)
        pillContainer = NSView()
        pillContainer.wantsLayer = true
        pillContainer.layer?.cornerRadius = 11
        pillContainer.layer?.backgroundColor = Theme.accentGlow.cgColor
        pillContainer.translatesAutoresizingMaskIntoConstraints = false
        pillContainer.heightAnchor.constraint(equalToConstant: 22).isActive = true
        pillContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true

        statusPill = NSTextField(labelWithString: "Loading…")
        statusPill.font = .systemFont(ofSize: 11, weight: .medium)
        statusPill.textColor = Theme.accent
        statusPill.backgroundColor = .clear
        statusPill.isBezeled = false
        statusPill.isEditable = false
        statusPill.alignment = .center
        statusPill.translatesAutoresizingMaskIntoConstraints = false

        pillContainer.addSubview(statusPill)
        NSLayoutConstraint.activate([
            statusPill.leadingAnchor.constraint(equalTo: pillContainer.leadingAnchor, constant: 12),
            statusPill.trailingAnchor.constraint(equalTo: pillContainer.trailingAnchor, constant: -12),
            statusPill.centerYAnchor.constraint(equalTo: pillContainer.centerYAnchor),
        ])
        hStack.addArrangedSubview(pillContainer)

        // Settings gear
        let gearBtn = NSButton(title: "⚙", target: self, action: #selector(settingsClicked))
        gearBtn.isBordered = false
        gearBtn.font = .systemFont(ofSize: 17)
        gearBtn.translatesAutoresizingMaskIntoConstraints = false
        gearBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true
        hStack.addArrangedSubview(gearBtn)

        root.addArrangedSubview(header)

        // Border line
        let borderLine = NSView()
        borderLine.wantsLayer = true
        borderLine.layer?.backgroundColor = Theme.border.cgColor
        borderLine.translatesAutoresizingMaskIntoConstraints = false
        borderLine.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(borderLine)

        // ── content ─────────────────────────────────────
        let contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false

        // Section label
        let secLabel = NSTextField(labelWithString: "DICTATIONS")
        secLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        secLabel.textColor = Theme.text3

        // Flipped document view (content grows downward)
        contentStack = FlippedView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        // Empty state
        emptyView = makeEmptyState()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addSubview(emptyView)
        NSLayoutConstraint.activate([
            emptyView.topAnchor.constraint(equalTo: contentStack.topAnchor, constant: 60),
            emptyView.centerXAnchor.constraint(equalTo: contentStack.centerXAnchor),
        ])

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = contentStack

        contentArea.addSubview(secLabel)
        contentArea.addSubview(scrollView)
        secLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            secLabel.topAnchor.constraint(equalTo: contentArea.topAnchor, constant: 14),
            secLabel.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor, constant: 16),
            scrollView.topAnchor.constraint(equalTo: secLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor, constant: -12),
            // Pin document view width to scroll view
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        root.addArrangedSubview(contentArea)
    }

    private func makeEmptyState() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 8

        let bundle = Bundle.main
        if let iconPath = bundle.path(forResource: "icon", ofType: "icns"),
           let img = NSImage(contentsOfFile: iconPath) {
            let iv = NSImageView(image: img)
            iv.imageScaling = .scaleProportionallyDown
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 72).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 72).isActive = true
            v.addArrangedSubview(iv)
        }

        let t = NSTextField(labelWithString: "No dictations yet")
        t.font = .systemFont(ofSize: 14, weight: .medium)
        t.textColor = Theme.text2
        t.alignment = .center
        v.addArrangedSubview(t)

        let h = NSTextField(labelWithString: "Hold Right Option to start dictating")
        h.font = .systemFont(ofSize: 12)
        h.textColor = Theme.text3
        h.alignment = .center
        v.addArrangedSubview(h)

        return v
    }

    func setState(_ state: AppState) {
        let label = Theme.stateLabel(state)
        statusPill?.stringValue = label
        if state == .idle {
            statusPill?.textColor = Theme.text3
            pillContainer?.layer?.backgroundColor = NSColor.clear.cgColor
            pillContainer?.layer?.borderWidth = 1
            pillContainer?.layer?.borderColor = Theme.border.cgColor
        } else {
            let c = Theme.stateColor(state)
            statusPill?.textColor = c
            pillContainer?.layer?.backgroundColor = c.withAlphaComponent(0.12).cgColor
            pillContainer?.layer?.borderWidth = 0
        }
    }

    func addEntry(text: String, time: String) {
        entries.insert(HistoryEntry(text: text, time: time), at: 0)

        if emptyView.superview != nil {
            emptyView.removeFromSuperview()
        }

        // Rebuild the entire content (simple and correct)
        rebuildContent()
    }

    private func rebuildContent() {
        // Remove all subviews
        contentStack.subviews.forEach { $0.removeFromSuperview() }
        bottomConstraint = nil
        lastCardBottomAnchor = nil

        if entries.isEmpty {
            emptyView.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addSubview(emptyView)
            NSLayoutConstraint.activate([
                emptyView.topAnchor.constraint(equalTo: contentStack.topAnchor, constant: 60),
                emptyView.centerXAnchor.constraint(equalTo: contentStack.centerXAnchor),
            ])
            return
        }

        var topAnchor = contentStack.topAnchor

        // Day label
        let dayLabel = NSTextField(labelWithString: "Today")
        dayLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        dayLabel.textColor = Theme.text2
        dayLabel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addSubview(dayLabel)
        NSLayoutConstraint.activate([
            dayLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            dayLabel.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: 2),
        ])
        topAnchor = dayLabel.bottomAnchor

        // Add cards (newest first, capped at 60)
        let capped = Array(entries.prefix(60))
        for entry in capped {
            let card = makeCard(text: entry.text, time: entry.time)
            card.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                card.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            ])
            topAnchor = card.bottomAnchor
        }

        // Pin bottom to size the document view for scrolling
        let bottom = topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    private func makeCard(text: String, time: String) -> NSView {
        let card = HoverCardView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Theme.card.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.border.cgColor

        let textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = Theme.text
        textLabel.maximumNumberOfLines = 0
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = Theme.text3

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyClicked(_:)))
        copyBtn.bezelStyle = .inline
        copyBtn.font = .systemFont(ofSize: 11)
        copyBtn.toolTip = text
        copyBtn.setContentHuggingPriority(.required, for: .horizontal)
        copyBtn.setContentCompressionResistancePriority(.required, for: .horizontal)

        card.addSubview(textLabel)
        card.addSubview(timeLabel)
        card.addSubview(copyBtn)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        copyBtn.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            textLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            textLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            textLabel.trailingAnchor.constraint(equalTo: copyBtn.leadingAnchor, constant: -10),

            copyBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            copyBtn.centerYAnchor.constraint(equalTo: card.centerYAnchor),

            timeLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 3),
            timeLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            timeLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])

        return card
    }

    @objc private func copyClicked(_ sender: NSButton) {
        guard let text = sender.toolTip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        // Green flash feedback
        if let card = sender.superview?.superview as? HoverCardView {
            card.layer?.backgroundColor = NSColor(r: 120, g: 180, b: 100, a: 15).cgColor
            card.layer?.borderColor = NSColor(r: 120, g: 180, b: 100, a: 30).cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                card.layer?.backgroundColor = Theme.card.cgColor
                card.layer?.borderColor = Theme.border.cgColor
            }
        }
    }

    @objc private func settingsClicked() { onSettings?() }

    private static func todayString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

class HoverCardView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Theme.cardHover.cgColor
        layer?.borderColor = Theme.borderHover.cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderColor = Theme.border.cgColor
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Settings Window
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onHotkeyChanged: ((String) -> Void)?
    var onWindowClosed: (() -> Void)?
    private var hotkeyPopup: NSPopUpButton!
    private var soundsCheck: NSButton!
    private var doubleTapField: NSTextField!

    init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Settings"
        w.center()
        w.backgroundColor = Theme.bg
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        setupUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        onWindowClosed?()
        return false
    }

    private func setupUI() {
        let s = UserSettings.shared
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 12; grid.columnSpacing = 12

        hotkeyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let keys = ["alt_r", "alt_l", "ctrl_r", "ctrl_l", "fn", "f5", "f6", "f7", "f8"]
        for k in keys {
            hotkeyPopup.addItem(withTitle: HotkeyManager.keyLabels[k] ?? k)
            hotkeyPopup.lastItem?.representedObject = k
        }
        hotkeyPopup.selectItem(withTitle: HotkeyManager.keyLabels[s.hotkey] ?? s.hotkey)
        grid.addRow(with: [lbl("Hotkey:"), hotkeyPopup])

        soundsCheck = NSButton(checkboxWithTitle: "Play sounds", target: nil, action: nil)
        soundsCheck.state = s.soundsEnabled ? .on : .off
        grid.addRow(with: [lbl("Sounds:"), soundsCheck])

        doubleTapField = NSTextField()
        doubleTapField.integerValue = s.doubleTapMs
        let dtRow = NSStackView(views: [doubleTapField, lbl("ms")])
        dtRow.orientation = .horizontal
        grid.addRow(with: [lbl("Double-tap:"), dtRow])

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        grid.addRow(with: [NSView(), saveBtn])

        let content = window!.contentView!
        content.addSubview(grid)
        grid.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            grid.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    private func lbl(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = Theme.text; l.font = .systemFont(ofSize: 13)
        return l
    }

    @objc private func save() {
        let s = UserSettings.shared
        let oldKey = s.hotkey
        if let newKey = hotkeyPopup.selectedItem?.representedObject as? String {
            s.hotkey = newKey
            if newKey != oldKey { onHotkeyChanged?(newKey) }
        }
        s.soundsEnabled = soundsCheck.state == .on
        s.doubleTapMs = doubleTapField.integerValue
        s.save()
        window?.close()
    }
}
