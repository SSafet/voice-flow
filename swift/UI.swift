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
    var onShowPermissions: (() -> Void)?
    var onToggleCapture: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var captureMenuItem: NSMenuItem!

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
        captureMenuItem = menu.addItem(withTitle: "Start Activity Capture", action: #selector(toggleCaptureAction), keyEquivalent: "")
        captureMenuItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show History", action: #selector(historyAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(permissionsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Flow", action: #selector(quitAction), keyEquivalent: "").target = self
        statusItem.menu = menu
    }

    func setState(_ state: AppState) {
        statusMenuItem?.title = "Voice Flow — \(Theme.stateLabel(state))"
    }

    func setCapturing(_ active: Bool) {
        captureMenuItem?.title = active ? "Stop Activity Capture" : "Start Activity Capture"
        captureMenuItem?.state = active ? .on : .off
    }

    @objc private func historyAction() { onShowHistory?() }
    @objc private func permissionsAction() { onShowPermissions?() }
    @objc private func settingsAction() { onShowSettings?() }
    @objc private func toggleCaptureAction() { onToggleCapture?() }
    @objc private func quitAction() { onQuit?() }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Floating Indicator (48×22 pill with 3 dots, Core Animation)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class FloatingIndicator: NSObject {
    var onClick: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onToggleCapture: (() -> Void)?

    private let W: CGFloat = 48, H: CGFloat = 16
    private let DOT_R: CGFloat = 3, DOT_SP: CGFloat = 10
    private var panel: NSPanel!
    private var pillLayer: CALayer!
    private var dotLayers: [CALayer] = []
    private var state: AppState = .idle
    private var isCapturing = false
    private var ttsSnapshot: TTSStatusSnapshot?

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
        pillLayer.cornerRadius = H / 2
        pillLayer.borderWidth = 1.0
        root.addSublayer(pillLayer)

        // Specular highlight
        let spec = CALayer()
        let specH = H * 0.42
        spec.frame = CGRect(x: 1.5, y: H - 1.0 - specH, width: W - 3, height: specH)
        spec.cornerRadius = H / 2 - 1
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

    func setCapturing(_ active: Bool) {
        isCapturing = active
        applyState()
    }

    func setTTSStatus(_ snapshot: TTSStatusSnapshot) {
        ttsSnapshot = snapshot
        applyState()
    }

    private func applyState() {
        pillLayer?.removeAllAnimations()
        dotLayers.forEach { $0.removeAllAnimations() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if state == .idle, !isCapturing, let snapshot = ttsSnapshot, applyTTSVisual(snapshot) {
            CATransaction.commit()
            return
        }

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

        // Capture state: red pulsing border overlay
        if isCapturing && state == .idle {
            pillLayer.borderColor = NSColor(r: 220, g: 60, b: 50, a: 180).cgColor
            pillLayer.borderWidth = 1.5
            addCapturePulse()
        } else if isCapturing {
            // Other states keep their colors, but still mark the border red
            pillLayer.borderColor = NSColor(r: 220, g: 60, b: 50, a: 120).cgColor
            pillLayer.borderWidth = 1.5
        } else {
            pillLayer.borderWidth = 1.0
        }
    }

    private func applyTTSVisual(_ snapshot: TTSStatusSnapshot) -> Bool {
        let isPaused = snapshot.message == "Paused"

        switch snapshot.phase {
        case .playing:
            pillLayer.backgroundColor = NSColor(r: 44, g: 84, b: 68, a: 125).cgColor
            pillLayer.borderColor = NSColor(r: 130, g: 220, b: 176, a: 60).cgColor
            dotLayers.forEach { $0.backgroundColor = NSColor(r: 228, g: 255, b: 244, a: 195).cgColor }
            addPulse(duration: 1.25)
            addDotFadeSweep(cycle: 1.0)
            return true
        case .generating:
            pillLayer.backgroundColor = NSColor(r: 62, g: 78, b: 54, a: 115).cgColor
            pillLayer.borderColor = NSColor(r: 190, g: 220, b: 132, a: 46).cgColor
            dotLayers.forEach { $0.backgroundColor = NSColor(r: 244, g: 255, b: 215, a: 185).cgColor }
            addPulse(duration: 1.5)
            addDotFadeSweep(cycle: 1.25)
            return true
        case .ready where isPaused:
            pillLayer.backgroundColor = NSColor(r: 42, g: 60, b: 54, a: 96).cgColor
            pillLayer.borderColor = NSColor(r: 140, g: 206, b: 182, a: 34).cgColor
            dotLayers.forEach { $0.backgroundColor = NSColor(r: 214, g: 236, b: 226, a: 145).cgColor }
            return true
        default:
            return false
        }
    }

    private func addCapturePulse() {
        let a = CABasicAnimation(keyPath: "borderColor")
        a.fromValue = NSColor(r: 220, g: 60, b: 50, a: 180).cgColor
        a.toValue = NSColor(r: 220, g: 60, b: 50, a: 60).cgColor
        a.duration = 1.5; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pillLayer.add(a, forKey: "capturePulse")
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

    private func addDotFadeSweep(cycle: Double) {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        for (i, dot) in dotLayers.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.35, 1.0, 0.45]
            a.keyTimes = [0.0, 0.45, 1.0]
            a.timingFunctions = [ease, ease]
            a.duration = cycle
            a.repeatCount = .infinity
            a.timeOffset = Double(i) * cycle / 4.0
            dot.add(a, forKey: "fadeSweep")
        }
    }

    private func showContextMenu(in view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        let captureItem = menu.addItem(
            withTitle: isCapturing ? "Stop Activity Capture" : "Start Activity Capture",
            action: #selector(ctxToggleCapture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show History", action: #selector(ctxHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Flow", action: #selector(ctxQuit), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: point, in: view)
    }
    @objc private func ctxToggleCapture() { onToggleCapture?() }
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

enum HistoryTab: Int {
    case dictations = 0
    case chat = 1
    case tts = 2
}

class HistoryWindowController: NSWindowController, NSWindowDelegate {
    var onSettings: (() -> Void)?
    var onWindowClosed: (() -> Void)?
    var onToggleCapture: (() -> Void)?
    var onTTSSpeak: ((TTSRequest) -> Void)?
    var onTTSSeek: ((Double) -> Void)?
    var onTTSStop: (() -> Void)?

    // Dictations tab
    private var entries: [HistoryEntry] = []
    private var contentStack: NSView!          // flipped document view
    private var bottomConstraint: NSLayoutConstraint?
    private var lastCardBottomAnchor: NSLayoutYAxisAnchor?
    private var emptyView: NSView!
    private var scrollView: NSScrollView!
    private var lastDay: String = ""

    // Conversation (Chat) tab
    private var conversationContainer: NSView!
    private var conversationContentStack: NSView!
    private var conversationScrollView: NSScrollView!
    private var conversationEmptyView: NSView!
    private var foundryStateLabel: NSTextField!

    // TTS tab
    private var ttsContainer: NSView!
    private var ttsStatusLabel: NSTextField!
    private var ttsServerLabel: NSTextField!
    private var ttsVoicePopup: NSPopUpButton!
    private var ttsStylePresetPopup: NSPopUpButton!
    private var ttsSpeedSlider: NSSlider!
    private var ttsSpeedValueLabel: NSTextField!
    private var ttsTimelineSlider: NSSlider!
    private var ttsTimelineValueLabel: NSTextField!
    private var ttsInstructionsField: NSTextField!
    private var ttsTextView: NSTextView!
    private var ttsSpeakButton: NSButton!
    private var ttsTimelineIsUpdating = false

    // Shared
    private var statusPill: NSTextField!
    private var pillContainer: NSView!
    private var segmentControl: NSSegmentedControl!
    private var dictationsContainer: NSView!

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

        // ── segment control ─────────────────────────────
        let segContainer = NSView()
        segContainer.wantsLayer = true
        segContainer.layer?.backgroundColor = Theme.bg.cgColor
        segContainer.translatesAutoresizingMaskIntoConstraints = false
        segContainer.heightAnchor.constraint(equalToConstant: 40).isActive = true

        segmentControl = NSSegmentedControl(labels: ["Dictations", "Chat", "TTS"], trackingMode: .selectOne,
                                            target: self, action: #selector(tabChanged))
        segmentControl.selectedSegment = 0
        segmentControl.translatesAutoresizingMaskIntoConstraints = false
        segContainer.addSubview(segmentControl)
        NSLayoutConstraint.activate([
            segmentControl.centerXAnchor.constraint(equalTo: segContainer.centerXAnchor),
            segmentControl.centerYAnchor.constraint(equalTo: segContainer.centerYAnchor),
        ])
        root.addArrangedSubview(segContainer)

        // ── dictations tab ─────────────────────────────
        dictationsContainer = NSView()
        dictationsContainer.translatesAutoresizingMaskIntoConstraints = false

        let secLabel = NSTextField(labelWithString: "DICTATIONS")
        secLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        secLabel.textColor = Theme.text3

        contentStack = FlippedView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false

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

        dictationsContainer.addSubview(secLabel)
        dictationsContainer.addSubview(scrollView)
        secLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            secLabel.topAnchor.constraint(equalTo: dictationsContainer.topAnchor, constant: 14),
            secLabel.leadingAnchor.constraint(equalTo: dictationsContainer.leadingAnchor, constant: 16),
            scrollView.topAnchor.constraint(equalTo: secLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: dictationsContainer.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: dictationsContainer.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: dictationsContainer.bottomAnchor, constant: -12),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // ── conversation (chat) tab ───────────────────
        conversationContainer = NSView()
        conversationContainer.translatesAutoresizingMaskIntoConstraints = false
        conversationContainer.isHidden = true

        let chatHeader = NSStackView()
        chatHeader.orientation = .horizontal
        chatHeader.spacing = 8
        chatHeader.translatesAutoresizingMaskIntoConstraints = false

        let chatLabel = NSTextField(labelWithString: "FOUNDRY CHAT")
        chatLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        chatLabel.textColor = Theme.text3

        foundryStateLabel = NSTextField(labelWithString: "Disconnected")
        foundryStateLabel.font = .systemFont(ofSize: 10, weight: .medium)
        foundryStateLabel.textColor = Theme.text3

        let chatSpacer = NSView()
        chatSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        chatHeader.addArrangedSubview(chatLabel)
        chatHeader.addArrangedSubview(chatSpacer)
        chatHeader.addArrangedSubview(foundryStateLabel)

        conversationContentStack = FlippedView()
        conversationContentStack.translatesAutoresizingMaskIntoConstraints = false

        conversationEmptyView = makeConversationEmptyState()
        conversationEmptyView.translatesAutoresizingMaskIntoConstraints = false
        conversationContentStack.addSubview(conversationEmptyView)
        NSLayoutConstraint.activate([
            conversationEmptyView.topAnchor.constraint(equalTo: conversationContentStack.topAnchor, constant: 60),
            conversationEmptyView.centerXAnchor.constraint(equalTo: conversationContentStack.centerXAnchor),
        ])

        conversationScrollView = NSScrollView()
        conversationScrollView.hasVerticalScroller = true
        conversationScrollView.drawsBackground = false
        conversationScrollView.scrollerStyle = .overlay
        conversationScrollView.documentView = conversationContentStack

        conversationContainer.addSubview(chatHeader)
        conversationContainer.addSubview(conversationScrollView)
        conversationScrollView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            chatHeader.topAnchor.constraint(equalTo: conversationContainer.topAnchor, constant: 14),
            chatHeader.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor, constant: 16),
            chatHeader.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor, constant: -16),
            conversationScrollView.topAnchor.constraint(equalTo: chatHeader.bottomAnchor, constant: 8),
            conversationScrollView.leadingAnchor.constraint(equalTo: conversationContainer.leadingAnchor, constant: 12),
            conversationScrollView.trailingAnchor.constraint(equalTo: conversationContainer.trailingAnchor, constant: -12),
            conversationScrollView.bottomAnchor.constraint(equalTo: conversationContainer.bottomAnchor, constant: -12),
            conversationContentStack.widthAnchor.constraint(equalTo: conversationScrollView.widthAnchor),
        ])

        // ── tts tab ───────────────────────────────────
        ttsContainer = NSView()
        ttsContainer.translatesAutoresizingMaskIntoConstraints = false
        ttsContainer.isHidden = true

        let ttsHeader = NSStackView()
        ttsHeader.orientation = .horizontal
        ttsHeader.spacing = 8
        ttsHeader.translatesAutoresizingMaskIntoConstraints = false

        let ttsLabel = NSTextField(labelWithString: "TEXT TO SPEECH")
        ttsLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        ttsLabel.textColor = Theme.text3

        let ttsHeaderSpacer = NSView()
        ttsHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        ttsStatusLabel = NSTextField(labelWithString: "Idle")
        ttsStatusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        ttsStatusLabel.textColor = Theme.text3

        ttsHeader.addArrangedSubview(ttsLabel)
        ttsHeader.addArrangedSubview(ttsHeaderSpacer)
        ttsHeader.addArrangedSubview(ttsStatusLabel)

        ttsVoicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for voice in OpenAITTSVoices {
            ttsVoicePopup.addItem(withTitle: voice)
        }
        ttsVoicePopup.selectItem(withTitle: UserSettings.shared.ttsVoice)
        ttsVoicePopup.target = self
        ttsVoicePopup.action = #selector(ttsControlsChanged)

        ttsStylePresetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        ttsStylePresetPopup.addItem(withTitle: "Quick styles…")
        for preset in OpenAITTSStylePresets {
            ttsStylePresetPopup.addItem(withTitle: preset.title)
        }
        ttsStylePresetPopup.selectItem(at: 0)
        ttsStylePresetPopup.target = self
        ttsStylePresetPopup.action = #selector(ttsStylePresetChanged)

        ttsSpeedSlider = NSSlider(value: UserSettings.shared.ttsSpeed, minValue: 0.25, maxValue: 4.0, target: self, action: #selector(ttsControlsChanged))
        ttsSpeedSlider.numberOfTickMarks = 16
        ttsSpeedSlider.allowsTickMarkValuesOnly = false

        ttsSpeedValueLabel = NSTextField(labelWithString: "")
        ttsSpeedValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ttsSpeedValueLabel.textColor = Theme.text2

        ttsTimelineSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(ttsTimelineChanged))
        ttsTimelineSlider.isEnabled = false
        ttsTimelineSlider.isContinuous = true

        ttsTimelineValueLabel = NSTextField(labelWithString: "00:00 / 00:00")
        ttsTimelineValueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        ttsTimelineValueLabel.textColor = Theme.text2

        ttsSpeakButton = NSButton(title: "Speak", target: self, action: #selector(ttsSpeakClicked))
        ttsSpeakButton.bezelStyle = .rounded

        let ttsStopButton = NSButton(title: "Stop", target: self, action: #selector(ttsStopClicked))
        ttsStopButton.bezelStyle = .rounded

        let ttsClearButton = NSButton(title: "Clear", target: self, action: #selector(ttsClearClicked))
        ttsClearButton.bezelStyle = .rounded

        let controlsRow = NSGridView(numberOfColumns: 2, rows: 0)
        controlsRow.rowSpacing = 10
        controlsRow.columnSpacing = 10

        let speedRow = NSStackView(views: [ttsSpeedSlider, ttsSpeedValueLabel])
        speedRow.orientation = .horizontal
        speedRow.spacing = 8

        let timelineRow = NSStackView(views: [ttsTimelineSlider, ttsTimelineValueLabel])
        timelineRow.orientation = .horizontal
        timelineRow.spacing = 8

        let buttonRow = NSStackView(views: [ttsSpeakButton, ttsStopButton, ttsClearButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        ttsInstructionsField = NSTextField(frame: .zero)
        ttsInstructionsField.stringValue = UserSettings.shared.ttsInstructions
        ttsInstructionsField.placeholderString = DefaultTTSInstructions
        ttsInstructionsField.target = self
        ttsInstructionsField.action = #selector(ttsControlsChanged)
        controlsRow.addRow(with: [gridLabel("Voice:"), ttsVoicePopup])
        controlsRow.addRow(with: [gridLabel("Preset:"), ttsStylePresetPopup])
        controlsRow.addRow(with: [gridLabel("Speed:"), speedRow])
        controlsRow.addRow(with: [gridLabel("Style:"), ttsInstructionsField])
        controlsRow.addRow(with: [gridLabel("Actions:"), buttonRow])
        controlsRow.addRow(with: [gridLabel("Timeline:"), timelineRow])
        controlsRow.translatesAutoresizingMaskIntoConstraints = false

        ttsServerLabel = NSTextField(labelWithString: "Local API: starting…")
        ttsServerLabel.font = .systemFont(ofSize: 11)
        ttsServerLabel.textColor = Theme.text3
        ttsServerLabel.lineBreakMode = .byWordWrapping
        ttsServerLabel.maximumNumberOfLines = 0
        ttsServerLabel.translatesAutoresizingMaskIntoConstraints = false

        let textScroll = NSScrollView()
        textScroll.drawsBackground = false
        textScroll.hasVerticalScroller = true
        textScroll.scrollerStyle = .overlay
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        ttsTextView = NSTextView(frame: .zero)
        ttsTextView.isRichText = false
        ttsTextView.isAutomaticQuoteSubstitutionEnabled = false
        ttsTextView.isAutomaticDashSubstitutionEnabled = false
        ttsTextView.isAutomaticTextCompletionEnabled = false
        ttsTextView.font = .systemFont(ofSize: 13)
        ttsTextView.textColor = Theme.text
        ttsTextView.backgroundColor = Theme.bgLighter
        ttsTextView.insertionPointColor = Theme.accent
        ttsTextView.isHorizontallyResizable = false
        ttsTextView.isVerticallyResizable = true
        ttsTextView.minSize = NSSize(width: 0, height: 0)
        ttsTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ttsTextView.textContainer?.widthTracksTextView = true
        ttsTextView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        ttsTextView.string = ""
        ttsTextView.textContainerInset = NSSize(width: 12, height: 12)
        textScroll.documentView = ttsTextView
        textScroll.contentView.postsBoundsChangedNotifications = true

        ttsContainer.addSubview(ttsHeader)
        ttsContainer.addSubview(controlsRow)
        ttsContainer.addSubview(ttsServerLabel)
        ttsContainer.addSubview(textScroll)

        NSLayoutConstraint.activate([
            ttsHeader.topAnchor.constraint(equalTo: ttsContainer.topAnchor, constant: 14),
            ttsHeader.leadingAnchor.constraint(equalTo: ttsContainer.leadingAnchor, constant: 16),
            ttsHeader.trailingAnchor.constraint(equalTo: ttsContainer.trailingAnchor, constant: -16),

            controlsRow.topAnchor.constraint(equalTo: ttsHeader.bottomAnchor, constant: 12),
            controlsRow.leadingAnchor.constraint(equalTo: ttsContainer.leadingAnchor, constant: 16),
            controlsRow.trailingAnchor.constraint(equalTo: ttsContainer.trailingAnchor, constant: -16),

            ttsServerLabel.topAnchor.constraint(equalTo: controlsRow.bottomAnchor, constant: 12),
            ttsServerLabel.leadingAnchor.constraint(equalTo: ttsContainer.leadingAnchor, constant: 16),
            ttsServerLabel.trailingAnchor.constraint(equalTo: ttsContainer.trailingAnchor, constant: -16),

            textScroll.topAnchor.constraint(equalTo: ttsServerLabel.bottomAnchor, constant: 10),
            textScroll.leadingAnchor.constraint(equalTo: ttsContainer.leadingAnchor, constant: 12),
            textScroll.trailingAnchor.constraint(equalTo: ttsContainer.trailingAnchor, constant: -12),
            textScroll.bottomAnchor.constraint(equalTo: ttsContainer.bottomAnchor, constant: -12),
        ])

        updateTTSSpeedLabel()

        // ── add all tabs to a content wrapper ─────────
        let contentArea = NSView()
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(dictationsContainer)
        contentArea.addSubview(conversationContainer)
        contentArea.addSubview(ttsContainer)

        NSLayoutConstraint.activate([
            dictationsContainer.topAnchor.constraint(equalTo: contentArea.topAnchor),
            dictationsContainer.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            dictationsContainer.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            dictationsContainer.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            conversationContainer.topAnchor.constraint(equalTo: contentArea.topAnchor),
            conversationContainer.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            conversationContainer.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            conversationContainer.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            ttsContainer.topAnchor.constraint(equalTo: contentArea.topAnchor),
            ttsContainer.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            ttsContainer.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            ttsContainer.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
        ])

        root.addArrangedSubview(contentArea)

        // Stretch all arranged subviews to fill the stack's width
        for v in root.arrangedSubviews {
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
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

    private func gridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text2
        return label
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

    // ── tab switching ─────────────────────────────────
    @objc private func tabChanged() {
        let tab = HistoryTab(rawValue: segmentControl.selectedSegment) ?? .dictations
        dictationsContainer.isHidden = tab != .dictations
        conversationContainer.isHidden = tab != .chat
        ttsContainer.isHidden = tab != .tts
    }

    func selectTab(_ tab: HistoryTab) {
        segmentControl.selectedSegment = tab.rawValue
        tabChanged()
    }

    // ── conversation (chat) tab ─────────────────────
    func setFoundryState(_ state: FoundryClient.ConnectionState) {
        let labels: [FoundryClient.ConnectionState: String] = [
            .disconnected: "Disconnected",
            .connecting: "Connecting…",
            .connected: "Connected",
            .subscribed: "Ready",
        ]
        foundryStateLabel?.stringValue = labels[state] ?? state.rawValue
        foundryStateLabel?.textColor = state == .subscribed ? Theme.accent : Theme.text3
    }

    func updateConversation(_ messages: [DisplayMessage]) {
        conversationContentStack.subviews.forEach { $0.removeFromSuperview() }

        if messages.isEmpty {
            conversationEmptyView.translatesAutoresizingMaskIntoConstraints = false
            conversationContentStack.addSubview(conversationEmptyView)
            NSLayoutConstraint.activate([
                conversationEmptyView.topAnchor.constraint(equalTo: conversationContentStack.topAnchor, constant: 60),
                conversationEmptyView.centerXAnchor.constraint(equalTo: conversationContentStack.centerXAnchor),
            ])
            return
        }

        var topAnchor = conversationContentStack.topAnchor

        for msg in messages {
            let card = makeConversationBubble(msg)
            card.translatesAutoresizingMaskIntoConstraints = false
            conversationContentStack.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                card.leadingAnchor.constraint(equalTo: conversationContentStack.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: conversationContentStack.trailingAnchor),
            ])
            topAnchor = card.bottomAnchor
        }

        let bottom = topAnchor.constraint(equalTo: conversationContentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true

        // Scroll to bottom
        DispatchQueue.main.async {
            let docH = self.conversationContentStack.frame.height
            let clipH = self.conversationScrollView.contentSize.height
            if docH > clipH {
                self.conversationContentStack.scroll(NSPoint(x: 0, y: docH - clipH))
            }
        }
    }

    private func makeConversationBubble(_ msg: DisplayMessage) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8

        let isUser = msg.role == .user
        card.layer?.backgroundColor = isUser
            ? NSColor(r: 60, g: 50, b: 35, a: 80).cgColor
            : NSColor(r: 40, g: 45, b: 55, a: 80).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = isUser
            ? NSColor(r: 212, g: 168, b: 83, a: 30).cgColor
            : NSColor(r: 100, g: 140, b: 200, a: 30).cgColor

        let roleSuffix = msg.isPending ? "  (pending)" : ""
        let roleLabel = NSTextField(labelWithString: (isUser ? "You" : "Agent") + roleSuffix)
        roleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        roleLabel.textColor = msg.isPending
            ? NSColor(r: 180, g: 160, b: 100)
            : (isUser ? Theme.accent : NSColor(r: 130, g: 170, b: 220))

        let contentLabel = NSTextField(wrappingLabelWithString: msg.content)
        contentLabel.font = .systemFont(ofSize: 12)
        contentLabel.textColor = Theme.text
        contentLabel.maximumNumberOfLines = 0
        contentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let streamingSuffix = msg.isStreaming ? " ▍" : ""
        if msg.isStreaming {
            contentLabel.stringValue = msg.content + streamingSuffix
        }

        card.addSubview(roleLabel)
        card.addSubview(contentLabel)
        roleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            roleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            roleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            contentLabel.topAnchor.constraint(equalTo: roleLabel.bottomAnchor, constant: 3),
            contentLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            contentLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            contentLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])

        return card
    }

    private func makeConversationEmptyState() -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .centerX
        v.spacing = 8

        let t = NSTextField(labelWithString: "No conversation yet")
        t.font = .systemFont(ofSize: 14, weight: .medium)
        t.textColor = Theme.text2
        t.alignment = .center
        v.addArrangedSubview(t)

        let h = NSTextField(labelWithString: "Start capture to connect to Foundry")
        h.font = .systemFont(ofSize: 12)
        h.textColor = Theme.text3
        h.alignment = .center
        v.addArrangedSubview(h)

        return v
    }

    func setCapturing(_ active: Bool) {
        // Capture state reflected via Foundry state label
    }

    func currentTTSRequest() -> TTSRequest {
        TTSRequest(
            text: ttsTextView?.string ?? "",
            voice: ttsVoicePopup?.selectedItem?.title ?? UserSettings.shared.ttsVoice,
            speed: ttsSpeedSlider?.doubleValue ?? UserSettings.shared.ttsSpeed,
            instructions: ttsInstructionsField?.stringValue ?? UserSettings.shared.ttsInstructions
        ).normalized()
    }

    func applyTTSRequest(_ request: TTSRequest) {
        let normalized = request.normalized()
        ttsTextView?.string = normalized.text
        ttsVoicePopup?.selectItem(withTitle: normalized.voice)
        ttsSpeedSlider?.doubleValue = normalized.speed
        ttsInstructionsField?.stringValue = normalized.instructions
        updateTTSSpeedLabel()
        persistTTSControls()
    }

    func setTTSStatus(_ snapshot: TTSStatusSnapshot) {
        ttsStatusLabel?.stringValue = snapshot.message
        switch snapshot.phase {
        case .idle:
            ttsStatusLabel?.textColor = Theme.text3
        case .generating:
            ttsStatusLabel?.textColor = Theme.accent
        case .ready:
            ttsStatusLabel?.textColor = Theme.text2
        case .playing:
            ttsStatusLabel?.textColor = NSColor(r: 120, g: 180, b: 100)
        case .error:
            ttsStatusLabel?.textColor = NSColor(r: 220, g: 90, b: 70)
        }

        ttsTimelineIsUpdating = true
        let duration = max(snapshot.duration, 0)
        ttsTimelineSlider?.minValue = 0
        ttsTimelineSlider?.maxValue = max(duration, 1)
        ttsTimelineSlider?.doubleValue = min(snapshot.currentTime, duration)
        ttsTimelineSlider?.isEnabled = snapshot.hasAudio && duration > 0
        ttsTimelineIsUpdating = false
        ttsTimelineValueLabel?.stringValue = "\(formatPlaybackTime(snapshot.currentTime)) / \(formatPlaybackTime(duration))"

        let hasText = !(ttsTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if snapshot.phase == .playing || snapshot.phase == .generating {
            ttsSpeakButton?.title = "Pause"
        } else if snapshot.hasAudio || hasText {
            ttsSpeakButton?.title = "Play"
        } else {
            ttsSpeakButton?.title = "Speak"
        }
    }

    func setTTSServerLabel(_ text: String) {
        ttsServerLabel?.stringValue = text
    }

    private func updateTTSSpeedLabel() {
        ttsSpeedValueLabel?.stringValue = String(format: "%.2fx", ttsSpeedSlider?.doubleValue ?? UserSettings.shared.ttsSpeed)
    }

    private func formatPlaybackTime(_ value: Double) -> String {
        let totalSeconds = max(Int(value.rounded(.down)), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func persistTTSControls() {
        let settings = UserSettings.shared
        settings.ttsVoice = ttsVoicePopup?.selectedItem?.title ?? settings.ttsVoice
        settings.ttsSpeed = ttsSpeedSlider?.doubleValue ?? settings.ttsSpeed
        settings.ttsInstructions = ttsInstructionsField?.stringValue ?? settings.ttsInstructions
        settings.save()
    }

    @objc private func ttsControlsChanged() {
        updateTTSSpeedLabel()
        persistTTSControls()
    }

    @objc private func ttsStylePresetChanged() {
        let index = ttsStylePresetPopup?.indexOfSelectedItem ?? 0
        guard index > 0, index - 1 < OpenAITTSStylePresets.count else { return }
        let preset = OpenAITTSStylePresets[index - 1]
        ttsInstructionsField?.stringValue = preset.instructions
        ttsStylePresetPopup?.selectItem(at: 0)
        persistTTSControls()
    }

    @objc private func ttsTimelineChanged() {
        guard !ttsTimelineIsUpdating else { return }
        onTTSSeek?(ttsTimelineSlider?.doubleValue ?? 0)
    }

    @objc private func ttsSpeakClicked() {
        onTTSSpeak?(currentTTSRequest())
    }

    @objc private func ttsStopClicked() {
        onTTSStop?()
    }

    @objc private func ttsClearClicked() {
        ttsTextView?.string = ""
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
//  Key Recorder Button (click → press any key/combo)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class KeyRecorderButton: NSButton {
    var currentSpec: HotkeySpec?
    var onRecorded: ((HotkeySpec) -> Void)?

    private var isRecording = false
    private var eventMonitor: Any?
    private var recordingPrompt: String?
    private var pendingCommitSpec: HotkeySpec?
    private var pendingCommitKeyCode: UInt16?
    private var pressedModifierKeyCodes: Set<UInt16> = []

    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    init(spec: HotkeySpec?) {
        super.init(frame: .zero)
        self.currentSpec = spec
        self.bezelStyle = .rounded
        self.target = self
        self.action = #selector(startRecording)
        self.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateTitle() {
        title = isRecording ? (recordingPrompt ?? "Hold modifiers, then press key") : (currentSpec?.label ?? "Click to set")
    }

    @objc private func startRecording() {
        stopRecording()
        isRecording = true
        recordingPrompt = "Hold modifiers, then press key"
        pendingCommitSpec = nil
        pendingCommitKeyCode = nil
        pressedModifierKeyCodes.removeAll()
        window?.makeFirstResponder(nil)
        updateTitle()

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }

            if let pendingKeyCode = self.pendingCommitKeyCode {
                if event.keyCode == pendingKeyCode {
                    if event.type == .keyUp {
                        self.commitPendingRecording()
                    } else if event.type == .flagsChanged,
                              !self.isModifierKeyDown(CGKeyCode(pendingKeyCode), flags: event.modifierFlags) {
                        self.commitPendingRecording()
                    }
                }
                return nil
            }

            guard self.isRecording else { return event }

            if event.type == .keyDown {
                return self.handleKeyDown(event)
            } else if event.type == .keyUp {
                return self.handleKeyUp(event)
            } else if event.type == .flagsChanged {
                return self.handleFlagsChanged(event)
            }
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let kc = CGKeyCode(event.keyCode)
        if kc == 53 {
            stopRecording()
            return nil
        }
        if event.isARepeat {
            return nil
        }
        guard !Self.modifierKeyCodes.contains(event.keyCode) else {
            return nil
        }

        let mods = recordingModifiers(from: event.modifierFlags)
        let label = HotkeySpec.buildLabel(keyCode: kc, modifiers: mods)
        armPendingRecording(
            HotkeySpec(keyCode: kc, modifiers: mods, label: label),
            commitOnReleaseOf: event.keyCode
        )
        return nil
    }

    private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        if pendingCommitKeyCode == event.keyCode {
            commitPendingRecording()
            return nil
        }
        if pendingCommitKeyCode != nil {
            return nil
        }
        return event
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        let kc = CGKeyCode(event.keyCode)
        guard Self.modifierKeyCodes.contains(event.keyCode) else { return event }

        let flags = event.modifierFlags
        let mods = recordingModifiers(from: flags)
        let isDown = isModifierKeyDown(kc, flags: flags)

        if isDown {
            pressedModifierKeyCodes.insert(event.keyCode)
            updateRecordingPrompt(with: mods)
            return nil
        }

        let wasPressed = pressedModifierKeyCodes.contains(event.keyCode)
        pressedModifierKeyCodes.remove(event.keyCode)

        if pendingCommitKeyCode == event.keyCode {
            commitPendingRecording()
            return nil
        }
        if pendingCommitKeyCode != nil {
            return nil
        }

        guard wasPressed else { return nil }

        let label = HotkeySpec.buildLabel(keyCode: kc, modifiers: mods)
        let spec = HotkeySpec(
            keyCode: kc,
            modifiers: mods,
            label: mods.isEmpty ? HotkeySpec.keyCodeName(kc) : label
        )
        finishRecording(spec)
        return nil
    }

    private func armPendingRecording(_ spec: HotkeySpec, commitOnReleaseOf keyCode: UInt16) {
        pendingCommitSpec = spec
        pendingCommitKeyCode = keyCode
        recordingPrompt = "Release to save \(spec.label)"
        updateTitle()
    }

    private func commitPendingRecording() {
        guard let spec = pendingCommitSpec else {
            stopRecording()
            return
        }
        pendingCommitSpec = nil
        pendingCommitKeyCode = nil
        finishRecording(spec)
    }

    private func finishRecording(_ spec: HotkeySpec) {
        currentSpec = spec
        recordingPrompt = nil
        pendingCommitSpec = nil
        pendingCommitKeyCode = nil
        pressedModifierKeyCodes.removeAll()
        stopRecording()
        onRecorded?(spec)
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        recordingPrompt = nil
        pendingCommitSpec = nil
        pendingCommitKeyCode = nil
        pressedModifierKeyCodes.removeAll()
        updateTitle()
    }

    private func updateRecordingPrompt(with modifiers: CGEventFlags) {
        if modifiers.isEmpty {
            recordingPrompt = "Hold modifiers, then press key"
        } else {
            recordingPrompt = "Release to save \(modifierLabel(for: modifiers))"
        }
        updateTitle()
    }

    private func recordingModifiers(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var mods = CGEventFlags()
        if flags.contains(.control)  { mods.insert(.maskControl) }
        if flags.contains(.option)   { mods.insert(.maskAlternate) }
        if flags.contains(.shift)    { mods.insert(.maskShift) }
        if flags.contains(.command)  { mods.insert(.maskCommand) }
        if flags.contains(.function) { mods.insert(.maskSecondaryFn) }
        return mods
    }

    private func modifierLabel(for modifiers: CGEventFlags) -> String {
        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("⌃") }
        if modifiers.contains(.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(.maskShift) { parts.append("⇧") }
        if modifiers.contains(.maskCommand) { parts.append("⌘") }
        if modifiers.contains(.maskSecondaryFn) { parts.append("Fn") }
        return parts.joined()
    }

    private func isModifierKeyDown(_ keyCode: CGKeyCode, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55:
            return flags.contains(.command)
        case 56, 60:
            return flags.contains(.shift)
        case 58, 61:
            return flags.contains(.option)
        case 59, 62:
            return flags.contains(.control)
        case 63:
            return flags.contains(.function)
        default:
            return false
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Permissions Window
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct PermissionViewState {
    let statusText: String
    let statusColor: NSColor
    let actionTitle: String
    let actionEnabled: Bool
}

class PermissionsWindowController: NSWindowController, NSWindowDelegate {
    var onRequestMicrophone: (() -> Void)?
    var onRequestScreenCapture: (() -> Void)?
    var onRequestAccessibility: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onWindowClosed: (() -> Void)?

    private var introLabel: NSTextField!
    private var microphoneStatusLabel: NSTextField!
    private var microphoneButton: NSButton!
    private var screenCaptureStatusLabel: NSTextField!
    private var screenCaptureButton: NSButton!
    private var accessibilityStatusLabel: NSTextField!
    private var accessibilityButton: NSButton!

    init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Permissions"
        w.center()
        w.backgroundColor = Theme.bg
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 320)
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

    func update(
        microphone: PermissionViewState,
        screenCapture: PermissionViewState,
        accessibility: PermissionViewState,
        allGranted: Bool
    ) {
        introLabel.stringValue = allGranted
            ? "All required permissions are granted. You can close this window."
            : "Grant permissions one at a time. If macOS opens System Settings, approve the permission there and return here. Use Refresh if a status lags."

        apply(state: microphone, to: microphoneStatusLabel, button: microphoneButton)
        apply(state: screenCapture, to: screenCaptureStatusLabel, button: screenCaptureButton)
        apply(state: accessibility, to: accessibilityStatusLabel, button: accessibilityButton)
    }

    private func setupUI() {
        let content = window!.contentView!

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        let titleLabel = NSTextField(labelWithString: "Permissions")
        titleLabel.font = .boldSystemFont(ofSize: 18)
        titleLabel.textColor = Theme.accent

        introLabel = NSTextField(labelWithString: "")
        introLabel.font = .systemFont(ofSize: 12)
        introLabel.textColor = Theme.text2
        introLabel.lineBreakMode = .byWordWrapping
        introLabel.maximumNumberOfLines = 0

        root.addArrangedSubview(titleLabel)
        root.addArrangedSubview(introLabel)
        root.addArrangedSubview(makeDivider())

        let microphoneRow = makePermissionRow(
            title: "Microphone",
            detail: "Needed for dictation input.",
            action: #selector(requestMicrophonePermission)
        )
        microphoneStatusLabel = microphoneRow.statusLabel
        microphoneButton = microphoneRow.button
        root.addArrangedSubview(microphoneRow.view)

        let screenCaptureRow = makePermissionRow(
            title: "Screen Recording",
            detail: "Needed for activity capture screenshots.",
            action: #selector(requestScreenCapturePermission)
        )
        screenCaptureStatusLabel = screenCaptureRow.statusLabel
        screenCaptureButton = screenCaptureRow.button
        root.addArrangedSubview(screenCaptureRow.view)

        let accessibilityRow = makePermissionRow(
            title: "Accessibility",
            detail: "Needed for global hotkeys and paste automation.",
            action: #selector(requestAccessibilityPermission)
        )
        accessibilityStatusLabel = accessibilityRow.statusLabel
        accessibilityButton = accessibilityRow.button
        root.addArrangedSubview(accessibilityRow.view)

        root.addArrangedSubview(makeDivider())

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPermissions))
        refreshButton.bezelStyle = .rounded

        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [buttonSpacer, refreshButton, closeButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        root.addArrangedSubview(footer)
    }

    private func makePermissionRow(title: String, detail: String, action: Selector) -> (view: NSView, statusLabel: NSTextField, button: NSButton) {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = Theme.text

        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = Theme.text3

        let statusLabel = NSTextField(labelWithString: "Checking…")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = Theme.text2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0

        let textStack = NSStackView(views: [titleLabel, detailLabel, statusLabel])
        textStack.orientation = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading

        let button = NSButton(title: "Request", target: self, action: action)
        button.bezelStyle = .rounded
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [textStack, spacer, button])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .top

        return (row, statusLabel, button)
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.border.cgColor
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    private func apply(state: PermissionViewState, to label: NSTextField, button: NSButton) {
        label.stringValue = state.statusText
        label.textColor = state.statusColor
        button.title = state.actionTitle
        button.isEnabled = state.actionEnabled
    }

    @objc private func requestMicrophonePermission() {
        onRequestMicrophone?()
    }

    @objc private func requestScreenCapturePermission() {
        onRequestScreenCapture?()
    }

    @objc private func requestAccessibilityPermission() {
        onRequestAccessibility?()
    }

    @objc private func refreshPermissions() {
        onRefresh?()
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Settings Window
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onHotkeyChanged: ((HotkeySpec) -> Void)?
    var onHandsFreeHotkeyChanged: ((HotkeySpec) -> Void)?
    var onTTSHotkeyChanged: ((HotkeySpec) -> Void)?
    var onCaptureHotkeyChanged: ((HotkeySpec) -> Void)?
    var onCaptureNoteHotkeyChanged: ((HotkeySpec) -> Void)?
    var onSettingsChanged: ((Bool) -> Void)?
    var onWindowClosed: (() -> Void)?

    private var providerPopup: NSPopUpButton!
    private var hotkeyRecorder: KeyRecorderButton!
    private var handsFreeHotkeyRecorder: KeyRecorderButton!
    private var ttsHotkeyRecorder: KeyRecorderButton!
    private var openAIKeyField: NSSecureTextField!
    private var openAIKeyStatusLabel: NSTextField!
    private var removeOpenAIKeyButton: NSButton!
    private var soundsCheck: NSButton!
    private var doubleTapField: NSTextField!
    private var llmCleanupCheck: NSButton!

    // Activity capture settings
    private var captureIntervalField: NSTextField!
    private var captureHotkeyRecorder: KeyRecorderButton!
    private var captureNoteHotkeyRecorder: KeyRecorderButton!

    // Foundry gateway settings
    private var gatewayHostField: NSTextField!
    private var gatewayWSPortField: NSTextField!
    private var gatewayHTTPPortField: NSTextField!
    private var tenantIdField: NSTextField!
    private var appIdField: NSTextField!
    private var userIdField: NSTextField!
    private var agentTypeField: NSTextField!
    private var sessionLabelField: NSTextField!

    init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        w.title = "Settings"
        w.center()
        w.backgroundColor = Theme.bg
        w.appearance = NSAppearance(named: .darkAqua)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 540)
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
        let foundry = s.foundryConfig
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.translatesAutoresizingMaskIntoConstraints = false

        // ── Dictation section ──
        let dictHeader = lbl("── Dictation ──")
        dictHeader.textColor = Theme.accent
        grid.addRow(with: [dictHeader, NSView()])

        providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for provider in DictationProvider.allCases {
            providerPopup.addItem(withTitle: provider.label)
            providerPopup.lastItem?.representedObject = provider.rawValue
        }
        if let item = providerPopup.itemArray.first(where: {
            ($0.representedObject as? String) == s.dictationProvider.rawValue
        }) {
            providerPopup.select(item)
        }
        providerPopup.target = self
        providerPopup.action = #selector(dictationProviderChanged)
        providerPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        grid.addRow(with: [lbl("Provider:"), providerPopup])

        hotkeyRecorder = KeyRecorderButton(spec: s.hotkey)
        hotkeyRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        grid.addRow(with: [lbl("Hold Key:"), hotkeyRecorder])

        handsFreeHotkeyRecorder = KeyRecorderButton(spec: s.handsFreeHotkey)
        handsFreeHotkeyRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        grid.addRow(with: [lbl("Double-Press:"), handsFreeHotkeyRecorder])

        ttsHotkeyRecorder = KeyRecorderButton(spec: s.ttsHotkey)
        ttsHotkeyRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        grid.addRow(with: [lbl("Speak Text:"), ttsHotkeyRecorder])

        openAIKeyField = NSSecureTextField(frame: .zero)
        openAIKeyField.stringValue = ""
        openAIKeyField.placeholderString = "sk-..."
        openAIKeyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        openAIKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        removeOpenAIKeyButton = NSButton(title: "Remove Saved Key", target: self, action: #selector(removeOpenAIKey))
        removeOpenAIKeyButton.bezelStyle = .rounded

        let keyRow = NSStackView(views: [openAIKeyField, removeOpenAIKeyButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyRow.alignment = .centerY
        grid.addRow(with: [lbl("OpenAI Key:"), keyRow])

        openAIKeyStatusLabel = NSTextField(labelWithString: "")
        openAIKeyStatusLabel.textColor = Theme.text2
        openAIKeyStatusLabel.font = .systemFont(ofSize: 11)
        openAIKeyStatusLabel.maximumNumberOfLines = 0
        openAIKeyStatusLabel.lineBreakMode = .byWordWrapping
        grid.addRow(with: [NSView(), openAIKeyStatusLabel])

        soundsCheck = NSButton(checkboxWithTitle: "Play sounds", target: nil, action: nil)
        soundsCheck.state = s.soundsEnabled ? .on : .off
        grid.addRow(with: [lbl("Sounds:"), soundsCheck])

        doubleTapField = NSTextField()
        doubleTapField.integerValue = s.doubleTapMs
        doubleTapField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let dtRow = NSStackView(views: [doubleTapField, lbl("ms")])
        dtRow.orientation = .horizontal
        dtRow.alignment = .centerY
        grid.addRow(with: [lbl("Double Window:"), dtRow])

        llmCleanupCheck = NSButton(checkboxWithTitle: "LLM text cleanup", target: nil, action: nil)
        llmCleanupCheck.state = s.llmCleanupEnabled ? .on : .off
        grid.addRow(with: [lbl("Cleanup:"), llmCleanupCheck])

        // ── Foundry Gateway section ──
        let foundryHeader = lbl("── Foundry Gateway ──")
        foundryHeader.textColor = Theme.accent
        grid.addRow(with: [foundryHeader, NSView()])

        gatewayHostField = NSTextField()
        gatewayHostField.stringValue = foundry.gatewayHost
        gatewayHostField.placeholderString = "127.0.0.1"
        gatewayHostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.addRow(with: [lbl("Host:"), gatewayHostField])

        gatewayWSPortField = NSTextField()
        gatewayWSPortField.integerValue = foundry.gatewayWSPort
        gatewayWSPortField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let wsRow = NSStackView(views: [gatewayWSPortField, lbl("WS")])
        wsRow.orientation = .horizontal
        wsRow.alignment = .centerY
        grid.addRow(with: [lbl("WS Port:"), wsRow])

        gatewayHTTPPortField = NSTextField()
        gatewayHTTPPortField.integerValue = foundry.gatewayHTTPPort
        gatewayHTTPPortField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let httpRow = NSStackView(views: [gatewayHTTPPortField, lbl("HTTP")])
        httpRow.orientation = .horizontal
        httpRow.alignment = .centerY
        grid.addRow(with: [lbl("HTTP Port:"), httpRow])

        tenantIdField = NSTextField()
        tenantIdField.stringValue = foundry.tenantId
        tenantIdField.placeholderString = "local"
        tenantIdField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.addRow(with: [lbl("Tenant ID:"), tenantIdField])

        appIdField = NSTextField()
        appIdField.stringValue = foundry.appId
        appIdField.placeholderString = "voice-flow"
        appIdField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.addRow(with: [lbl("App ID:"), appIdField])

        userIdField = NSTextField()
        userIdField.stringValue = foundry.userId
        userIdField.placeholderString = "current app user"
        userIdField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.addRow(with: [lbl("User ID:"), userIdField])

        agentTypeField = NSTextField()
        agentTypeField.stringValue = foundry.agentType
        agentTypeField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.addRow(with: [lbl("Agent Type:"), agentTypeField])

        sessionLabelField = NSTextField()
        sessionLabelField.stringValue = foundry.sessionLabel
        sessionLabelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        grid.addRow(with: [lbl("Session Label:"), sessionLabelField])

        captureIntervalField = NSTextField()
        captureIntervalField.integerValue = s.captureIntervalSeconds
        captureIntervalField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let intRow = NSStackView(views: [captureIntervalField, lbl("sec")])
        intRow.orientation = .horizontal
        intRow.alignment = .centerY
        grid.addRow(with: [lbl("Interval:"), intRow])

        captureHotkeyRecorder = KeyRecorderButton(spec: s.captureHotkey)
        captureHotkeyRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        grid.addRow(with: [lbl("Capture Key:"), captureHotkeyRecorder])

        captureNoteHotkeyRecorder = KeyRecorderButton(spec: s.captureNoteHotkey)
        captureNoteHotkeyRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        grid.addRow(with: [lbl("Note Key:"), captureNoteHotkeyRecorder])

        // Save button
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded; saveBtn.keyEquivalent = "\r"
        grid.addRow(with: [NSView(), saveBtn])

        let content = window!.contentView!
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay

        let docView = FlippedView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = docView

        content.addSubview(scrollView)
        docView.addSubview(grid)

        if grid.numberOfColumns >= 2 {
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .fill
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            docView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            docView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            docView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            docView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            docView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            grid.topAnchor.constraint(equalTo: docView.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 22),
            grid.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -22),
            grid.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -22),
        ])

        refreshOpenAIKeyUI()
        refreshDictationUI()
        fitWindowToContent(grid)
    }

    private func lbl(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = Theme.text
        l.font = .systemFont(ofSize: 13)
        l.setContentCompressionResistancePriority(.required, for: .horizontal)
        return l
    }

    private func fitWindowToContent(_ grid: NSGridView) {
        guard let window, let content = window.contentView else { return }

        content.layoutSubtreeIfNeeded()

        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let preferredWidth = min(max(560, grid.fittingSize.width + 64), visibleFrame.width * 0.8)
        let preferredHeight = min(max(640, grid.fittingSize.height + 64), visibleFrame.height * 0.85)

        window.setContentSize(NSSize(width: preferredWidth, height: preferredHeight))
        window.minSize = NSSize(width: min(preferredWidth, 560), height: 540)
    }

    private func selectedDictationProvider() -> DictationProvider {
        guard let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = DictationProvider(rawValue: raw) else {
            return .local
        }
        return provider
    }

    private func refreshDictationUI() {
        let isLocal = selectedDictationProvider() == .local
        llmCleanupCheck.isEnabled = isLocal
        llmCleanupCheck.alphaValue = isLocal ? 1.0 : 0.5
    }

    private func refreshOpenAIKeyUI(statusMessage: String? = nil) {
        let hasKey = KeychainStore.shared.hasOpenAIAPIKey
        openAIKeyField.stringValue = ""
        openAIKeyField.placeholderString = hasKey
            ? "••••••••••••••••"
            : "sk-..."
        openAIKeyStatusLabel.stringValue = statusMessage ?? (
            hasKey
                ? "Saved in macOS Keychain. Enter a new key only if you want to replace it."
                : "Stored securely in macOS Keychain when you save."
        )
        removeOpenAIKeyButton.isEnabled = hasKey
    }

    @objc private func dictationProviderChanged() {
        refreshDictationUI()
    }

    @objc private func removeOpenAIKey() {
        guard KeychainStore.shared.removeOpenAIAPIKey() else {
            NSSound.beep()
            refreshOpenAIKeyUI(statusMessage: "Failed to remove the saved OpenAI key.")
            return
        }
        openAIKeyField.stringValue = ""
        refreshOpenAIKeyUI(statusMessage: "Saved OpenAI key removed from macOS Keychain.")
    }

    @objc private func save() {
        let s = UserSettings.shared
        let previousFoundryConfig = s.foundryConfig

        let provider = selectedDictationProvider()
        s.dictationProvider = provider

        let newOpenAIKey = openAIKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newOpenAIKey.isEmpty {
            guard KeychainStore.shared.saveOpenAIAPIKey(newOpenAIKey) else {
                NSSound.beep()
                refreshOpenAIKeyUI(statusMessage: "Failed to save the OpenAI key to Keychain.")
                return
            }
            openAIKeyField.stringValue = ""
            refreshOpenAIKeyUI(statusMessage: "OpenAI key updated in macOS Keychain.")
        } else if provider == .openai && !KeychainStore.shared.hasOpenAIAPIKey {
            NSSound.beep()
            refreshOpenAIKeyUI(statusMessage: "Enter an OpenAI API key or switch back to Local.")
            return
        }

        if let spec = hotkeyRecorder.currentSpec {
            if spec.keyCode != s.hotkey.keyCode || spec.modifiers != s.hotkey.modifiers {
                s.hotkey = spec
                onHotkeyChanged?(spec)
            }
        }
        if let spec = handsFreeHotkeyRecorder.currentSpec {
            if spec.keyCode != s.handsFreeHotkey.keyCode || spec.modifiers != s.handsFreeHotkey.modifiers {
                s.handsFreeHotkey = spec
                onHandsFreeHotkeyChanged?(spec)
            }
        }
        if let spec = ttsHotkeyRecorder.currentSpec {
            if spec.keyCode != s.ttsHotkey.keyCode || spec.modifiers != s.ttsHotkey.modifiers {
                s.ttsHotkey = spec
                onTTSHotkeyChanged?(spec)
            }
        }
        s.soundsEnabled = soundsCheck.state == .on
        s.doubleTapMs = doubleTapField.integerValue
        s.llmCleanupEnabled = llmCleanupCheck.state == .on

        // Foundry gateway settings
        s.gatewayHost = gatewayHostField.stringValue
        s.gatewayWSPort = max(1, gatewayWSPortField.integerValue)
        s.gatewayHTTPPort = max(1, gatewayHTTPPortField.integerValue)
        s.tenantId = tenantIdField.stringValue
        s.appId = appIdField.stringValue
        s.userId = userIdField.stringValue
        s.agentType = agentTypeField.stringValue
        s.sessionLabel = sessionLabelField.stringValue
        s.captureIntervalSeconds = max(5, captureIntervalField.integerValue)
        if let spec = captureHotkeyRecorder.currentSpec {
            if spec.keyCode != s.captureHotkey.keyCode || spec.modifiers != s.captureHotkey.modifiers {
                s.captureHotkey = spec
                onCaptureHotkeyChanged?(spec)
            }
        }
        if let spec = captureNoteHotkeyRecorder.currentSpec {
            if spec.keyCode != s.captureNoteHotkey.keyCode || spec.modifiers != s.captureNoteHotkey.modifiers {
                s.captureNoteHotkey = spec
                onCaptureNoteHotkeyChanged?(spec)
            }
        }

        s.save()
        onSettingsChanged?(previousFoundryConfig != s.foundryConfig)
        window?.close()
    }
}
