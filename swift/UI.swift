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
    var onToggleSession: (() -> Void)?
    var onToggleAnnotate: (() -> Void)?
    var onShowChat: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var sessionMenuItem: NSMenuItem!

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
        sessionMenuItem = menu.addItem(withTitle: "Start Session", action: #selector(toggleSessionAction), keyEquivalent: "")
        sessionMenuItem.target = self
        menu.addItem(withTitle: "Annotate Screen", action: #selector(annotateAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Chat", action: #selector(chatAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Dictation History", action: #selector(historyAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(permissionsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Flow", action: #selector(quitAction), keyEquivalent: "").target = self
        statusItem.menu = menu
    }

    func setState(_ state: AppState) {
        statusMenuItem?.title = "Voice Flow — \(Theme.stateLabel(state))"
    }

    func setSessionActive(_ active: Bool) {
        sessionMenuItem?.title = active ? "End Session" : "Start Session"
        sessionMenuItem?.state = active ? .on : .off
    }

    @objc private func historyAction() { onShowHistory?() }
    @objc private func permissionsAction() { onShowPermissions?() }
    @objc private func settingsAction() { onShowSettings?() }
    @objc private func toggleSessionAction() { onToggleSession?() }
    @objc private func annotateAction() { onToggleAnnotate?() }
    @objc private func chatAction() { onShowChat?() }
    @objc private func quitAction() { onQuit?() }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Floating Indicator (48×22 pill with 3 dots, Core Animation)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class FloatingIndicator: NSObject {
    var onClick: (() -> Void)?
    var onQuit: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onToggleSession: (() -> Void)?
    var onToggleAnnotate: (() -> Void)?

    private let W: CGFloat = 52, H: CGFloat = 18
    private let DOT_R: CGFloat = 3, DOT_SP: CGFloat = 11

    private var panel: NSPanel!
    private var pillLayer: CALayer!
    private var sessionRingLayer: CALayer!
    private var dotLayers: [CALayer] = []

    private var state: AppState = .idle
    private var sessionActive = false
    private var agentActivity: AgentActivity = .idle
    private var ttsSnapshot: TTSStatusSnapshot?
    private var recordingPurpose: RecordingPurpose = .dictation
    private var appliedVisual: Visual?
    private var appliedRing: Bool?

    func show() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false

        let rootView = IndicatorView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        rootView.onClick = { [weak self] in self?.onClick?() }
        rootView.onRightClick = { [weak self] view, point in self?.showContextMenu(in: view, at: point) }
        rootView.wantsLayer = true
        let root = rootView.layer!

        // Pill background — inset by 1pt so the session ring has room.
        pillLayer = CALayer()
        pillLayer.frame = CGRect(x: 1, y: 1, width: W - 2, height: H - 2)
        pillLayer.cornerRadius = (H - 2) / 2
        pillLayer.borderWidth = 1.0
        root.addSublayer(pillLayer)

        // Session ring — visible while a session is live.
        sessionRingLayer = CALayer()
        sessionRingLayer.frame = CGRect(x: 0, y: 0, width: W, height: H)
        sessionRingLayer.cornerRadius = H / 2
        sessionRingLayer.backgroundColor = NSColor.clear.cgColor
        sessionRingLayer.borderColor = NSColor(r: 255, g: 128, b: 96, a: 200).cgColor
        sessionRingLayer.borderWidth = 0
        sessionRingLayer.opacity = 0
        sessionRingLayer.shadowColor = NSColor(r: 255, g: 128, b: 96, a: 255).cgColor
        sessionRingLayer.shadowOffset = .zero
        root.addSublayer(sessionRingLayer)

        // 3 dots, centered as a group on the pill
        let cy = H / 2.0
        let firstDotX = W / 2.0 - DOT_SP
        for i in 0..<3 {
            let dot = CALayer()
            let x = firstDotX + CGFloat(i) * DOT_SP
            dot.frame = CGRect(x: x - DOT_R, y: cy - DOT_R, width: DOT_R * 2, height: DOT_R * 2)
            dot.cornerRadius = DOT_R
            root.addSublayer(dot)
            dotLayers.append(dot)
        }

        panel.contentView = rootView
        recenter()
        panel.orderFront(nil)
        applyState()

        // Screen layout changes and sleep/wake both silently kill CA
        // animations or move the pill — reapply on both.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wokeUp),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func screenChanged() {
        recenter()
        applyState(force: true)
    }

    @objc private func wokeUp() {
        applyState(force: true)
    }

    private func recenter() {
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let frame = screen.frame
        let x = (frame.minX + (frame.width - W) / 2).rounded()
        let y = (frame.minY + 5).rounded()
        panel.setFrame(NSRect(x: x, y: y, width: W, height: H), display: true)
    }

    // ── State inputs ────────────────────────────────────

    func setState(_ newState: AppState, recordingFor purpose: RecordingPurpose = .dictation) {
        state = newState
        recordingPurpose = purpose
        applyState()
        if newState == .done {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if self.state == .done { self.state = .idle; self.applyState() }
            }
        }
    }

    func setSessionActive(_ active: Bool) {
        sessionActive = active
        applyState()
    }

    func setAgentActivity(_ activity: AgentActivity) {
        agentActivity = activity
        applyState()
    }

    func setTTSStatus(_ snapshot: TTSStatusSnapshot) {
        ttsSnapshot = snapshot
        applyState()
    }

    // ── Rendering ───────────────────────────────────────
    // Priority when dictation is idle: agent activity > TTS > plain idle.
    //
    // Everything the pill can show is reduced to one Visual value; applyState()
    // re-paints (and restarts the repeating animations) only when that value
    // changes. Status churn — the 10 Hz TTS playback snapshots, repeated agent
    // activity emissions — must not reset a running loop to its first frame.

    private enum Visual: Equatable {
        case idle, handsFree, processing, done
        case recording(RecordingPurpose)
        case agent(AgentActivity)
        case ttsPlaying, ttsGenerating, ttsPaused
    }

    private func resolveVisual() -> Visual {
        switch state {
        case .recording: return .recording(recordingPurpose)
        case .handsFree: return .handsFree
        case .processing, .loading: return .processing
        case .done: return .done
        case .idle: break
        }
        if agentActivity != .idle { return .agent(agentActivity) }
        if let snapshot = ttsSnapshot {
            switch snapshot.phase {
            case .playing: return .ttsPlaying
            case .generating: return .ttsGenerating
            case .ready where snapshot.message == "Paused": return .ttsPaused
            default: break
            }
        }
        return .idle
    }

    private func applyState(force: Bool = false) {
        guard pillLayer != nil else { return }

        // The session ring is orthogonal to the pill visual — updating it
        // alone must not restart the pill/dot loops.
        if force || appliedRing != sessionActive {
            appliedRing = sessionActive
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sessionRingLayer.borderWidth = sessionActive ? 1.5 : 0
            sessionRingLayer.opacity = sessionActive ? 1.0 : 0.0
            CATransaction.commit()
        }

        let visual = resolveVisual()
        if !force, visual == appliedVisual { return }
        appliedVisual = visual

        pillLayer.removeAllAnimations()
        dotLayers.forEach { $0.removeAllAnimations() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.borderWidth = 1.0
        pillLayer.shadowOpacity = 0
        pillLayer.shadowRadius = 0
        CATransaction.commit()

        switch visual {
        case .recording(let purpose):
            // Hue says where the words are going; the pulse+scale motion is
            // the shared "mic is live" signature.
            switch purpose {
            case .dictation, .session:
                paint(bg: NSColor(r: 110, g: 50, b: 45, a: 115),
                      border: NSColor(r: 220, g: 160, b: 140, a: 45),
                      dots: NSColor(r: 255, g: 240, b: 220, a: 180))
            case .talk:
                paint(bg: NSColor(r: 72, g: 52, b: 100, a: 130),
                      border: NSColor(r: 176, g: 140, b: 240, a: 60),
                      dots: NSColor(r: 232, g: 222, b: 255, a: 200))
            case .snapTalk:
                paint(bg: NSColor(r: 34, g: 74, b: 94, a: 130),
                      border: NSColor(r: 110, g: 205, b: 235, a: 60),
                      dots: NSColor(r: 222, g: 244, b: 255, a: 200))
            }
            addPulse(duration: 1.45)
            addDotScale(cycle: 2.4)

        case .handsFree:
            paint(bg: NSColor(r: 100, g: 75, b: 30, a: 120),
                  border: NSColor(r: 230, g: 190, b: 100, a: 50),
                  dots: NSColor(r: 255, g: 240, b: 200, a: 190))
            addPulse(duration: 1.6)
            addDotScale(cycle: 2.8)

        case .processing:
            paint(bg: NSColor(r: 100, g: 80, b: 40, a: 110),
                  border: NSColor(r: 212, g: 168, b: 83, a: 45),
                  dots: NSColor(r: 255, g: 240, b: 200, a: 170))
            addPulse(duration: 1.8)
            addDotBounce(cycle: 2.1)

        case .done:
            paint(bg: NSColor(r: 60, g: 90, b: 50, a: 120),
                  border: NSColor(r: 160, g: 210, b: 140, a: 50),
                  dots: NSColor(r: 255, g: 245, b: 220, a: 190))

        case .agent(let activity):
            applyAgentVisual(activity)

        case .ttsPlaying:
            paint(bg: NSColor(r: 44, g: 84, b: 68, a: 125),
                  border: NSColor(r: 130, g: 220, b: 176, a: 60),
                  dots: NSColor(r: 228, g: 255, b: 244, a: 195))
            addPulse(duration: 1.25)
            addDotFadeSweep(cycle: 1.0)

        case .ttsGenerating:
            paint(bg: NSColor(r: 62, g: 78, b: 54, a: 115),
                  border: NSColor(r: 190, g: 220, b: 132, a: 46),
                  dots: NSColor(r: 244, g: 255, b: 215, a: 185))
            addPulse(duration: 1.5)
            addDotFadeSweep(cycle: 1.25)

        case .ttsPaused:
            paint(bg: NSColor(r: 42, g: 60, b: 54, a: 96),
                  border: NSColor(r: 140, g: 206, b: 182, a: 34),
                  dots: NSColor(r: 214, g: 236, b: 226, a: 145))

        case .idle:
            paint(bg: NSColor(r: 55, g: 48, b: 40, a: 90),
                  border: NSColor(r: 255, g: 220, b: 180, a: 16),
                  dots: NSColor(r: 255, g: 240, b: 220, a: 110))
        }
    }

    private func applyAgentVisual(_ activity: AgentActivity) {
        switch activity {
        case .thinking:
            paint(bg: NSColor(r: 58, g: 60, b: 92, a: 130),
                  border: NSColor(r: 140, g: 150, b: 235, a: 60),
                  dots: NSColor(r: 220, g: 226, b: 255, a: 190))
            addPulse(duration: 1.6)
            addDotFadeSweep(cycle: 1.2)
        case .responding:
            paint(bg: NSColor(r: 46, g: 66, b: 92, a: 130),
                  border: NSColor(r: 120, g: 175, b: 240, a: 60),
                  dots: NSColor(r: 216, g: 236, b: 255, a: 200))
            addDotFadeSweep(cycle: 0.9)
        case .acting:
            paint(bg: NSColor(r: 112, g: 52, b: 40, a: 150),
                  border: NSColor(r: 255, g: 130, b: 100, a: 90),
                  dots: NSColor(r: 255, g: 230, b: 220, a: 210))
            addPulse(duration: 0.9)
            addDotScale(cycle: 1.4)
            // Danger glow on the pill itself (the session ring is invisible
            // outside a session, so its shadow can't carry this).
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pillLayer.shadowColor = NSColor(r: 255, g: 130, b: 100, a: 255).cgColor
            pillLayer.shadowOffset = .zero
            pillLayer.shadowOpacity = 0.8
            pillLayer.shadowRadius = 5
            CATransaction.commit()
        case .idle:
            break
        }
    }

    private func paint(bg: NSColor, border: NSColor, dots: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.backgroundColor = bg.cgColor
        pillLayer.borderColor = border.cgColor
        dotLayers.forEach { $0.backgroundColor = dots.cgColor }
        CATransaction.commit()
    }

    func flashCapturePulse() {
        guard sessionActive, let sessionRingLayer else { return }
        sessionRingLayer.removeAnimation(forKey: "captureFlash")

        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let width = CAKeyframeAnimation(keyPath: "borderWidth")
        width.values = [1.5, 3.5, 1.5]
        width.keyTimes = [0.0, 0.45, 1.0]
        width.timingFunctions = [ease, ease]

        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0.0, 0.85, 0.0]
        glow.keyTimes = [0.0, 0.45, 1.0]
        glow.timingFunctions = [ease, ease]

        let radius = CAKeyframeAnimation(keyPath: "shadowRadius")
        radius.values = [0.0, 6.0, 0.0]
        radius.keyTimes = [0.0, 0.45, 1.0]
        radius.timingFunctions = [ease, ease]

        let flash = CAAnimationGroup()
        flash.animations = [width, glow, radius]
        flash.duration = 0.4
        flash.isRemovedOnCompletion = true
        sessionRingLayer.add(flash, forKey: "captureFlash")
    }

    // ── Animations ─────────────────────────────────────
    // All repeating animations use beginTime (not timeOffset) so phase
    // shifts land correctly and the loops stay smooth.

    private func addPulse(duration: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.72; a.toValue = 1.0
        a.duration = duration; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pillLayer.add(a, forKey: "pulse")
    }

    private func addDotScale(cycle: Double) {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let now = CACurrentMediaTime()
        for (i, dot) in dotLayers.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = [1.0, 1.35, 1.0]
            a.keyTimes = [0.0, 0.5, 1.0]
            a.timingFunctions = [ease, ease]
            a.duration = cycle; a.repeatCount = .infinity
            a.beginTime = now - Double(i) * cycle / 3.0
            dot.add(a, forKey: "scale")
        }
    }

    private func addDotBounce(cycle: Double) {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let now = CACurrentMediaTime()
        let cy = H / 2.0
        for (i, dot) in dotLayers.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "position.y")
            a.values = [cy, cy + 2.5, cy]
            a.keyTimes = [0.0, 0.5, 1.0]
            a.timingFunctions = [ease, ease]
            a.duration = cycle; a.repeatCount = .infinity
            a.beginTime = now - Double(i) * cycle / 3.0
            dot.add(a, forKey: "bounce")
        }
    }

    private func addDotFadeSweep(cycle: Double) {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let now = CACurrentMediaTime()
        for (i, dot) in dotLayers.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [0.35, 1.0, 0.45]
            a.keyTimes = [0.0, 0.45, 1.0]
            a.timingFunctions = [ease, ease]
            a.duration = cycle
            a.repeatCount = .infinity
            a.beginTime = now - Double(i) * cycle / 4.0
            dot.add(a, forKey: "fadeSweep")
        }
    }

    private func showContextMenu(in view: NSView, at point: NSPoint) {
        let menu = NSMenu()
        let sessionItem = menu.addItem(
            withTitle: sessionActive ? "End Session" : "Start Session",
            action: #selector(ctxToggleSession), keyEquivalent: "")
        sessionItem.target = self
        menu.addItem(withTitle: "Annotate Screen", action: #selector(ctxAnnotate), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Dictation History", action: #selector(ctxHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Flow", action: #selector(ctxQuit), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: point, in: view)
    }
    @objc private func ctxToggleSession() { onToggleSession?() }
    @objc private func ctxAnnotate() { onToggleAnnotate?() }
    @objc private func ctxHistory() { onShowHistory?() }
    @objc private func ctxQuit() { onQuit?() }
}

class IndicatorView: NSView {
    var onClick: (() -> Void)?
    var onRightClick: ((NSView, NSPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(self, convert(event.locationInWindow, from: nil))
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Dictation history entry (shown in the ChatPanel Dictations tab)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct HistoryEntry: Codable {
    let text: String
    let time: String
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Floating Transcript Panel (fallback for non-AX apps)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class FloatingTranscriptPanel {
    private var panel: NSPanel?
    private var textLabel: NSTextField!
    private let maxW: CGFloat = 500
    private let padding: CGFloat = 12
    private let radius: CGFloat = 10

    func show() {
        if panel != nil { panel?.orderFront(nil); return }

        let screen = NSScreen.main!.frame
        let initialW: CGFloat = 200
        let initialH: CGFloat = 40
        let x = (screen.width - initialW) / 2
        let y: CGFloat = 28

        let p = NSPanel(
            contentRect: NSRect(x: x, y: y, width: initialW, height: initialH),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.ignoresMouseEvents = true
        p.alphaValue = 0

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: initialW, height: initialH))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor(r: 28, g: 26, b: 24, a: 220).cgColor
        bg.layer?.cornerRadius = radius
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor(r: 255, g: 220, b: 180, a: 25).cgColor

        textLabel = NSTextField(wrappingLabelWithString: "")
        textLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textLabel.textColor = Theme.text
        textLabel.backgroundColor = .clear
        textLabel.isBordered = false
        textLabel.isEditable = false
        textLabel.isSelectable = false
        textLabel.maximumNumberOfLines = 6
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.preferredMaxLayoutWidth = maxW - padding * 2
        textLabel.frame = NSRect(x: padding, y: padding / 2, width: initialW - padding * 2, height: initialH - padding)

        bg.addSubview(textLabel)
        p.contentView = bg

        panel = p
        p.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }
    }

    func setText(_ text: String) {
        guard let panel, let textLabel else { return }
        if text.isEmpty {
            textLabel.stringValue = "Listening…"
            textLabel.textColor = Theme.text3
        } else {
            textLabel.stringValue = text
            textLabel.textColor = Theme.text
        }

        let maxTextW = maxW - padding * 2
        let size = textLabel.sizeThatFits(NSSize(width: maxTextW, height: CGFloat.greatestFiniteMagnitude))
        let newW = min(maxW, max(200, size.width + padding * 2))
        let newH = max(40, size.height + padding)

        textLabel.frame = NSRect(x: padding, y: padding / 2, width: newW - padding * 2, height: size.height)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: newW, height: newH)

        let screen = NSScreen.main!.frame
        let x = (screen.width - newW) / 2
        panel.setFrame(NSRect(x: x, y: 28, width: newW, height: newH), display: true)
    }

    func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            self.panel = nil
            self.textLabel = nil
        })
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Dictations view — browsable, copyable dictation history
//  Hosted as a tab inside ChatPanel. Persists to
//  ~/.config/voice-flow/dictations.json so history survives restarts.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class DictationsView: NSView {
    private var entries: [HistoryEntry] = []
    private var contentStack: NSView!          // flipped document view
    private var emptyView: NSView!
    private var scrollView: NSScrollView!

    private let renderCap = 60
    private let storeCap = 200
    private static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-flow/dictations.json")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        entries = DictationsView.loadEntries()
        setupUI()
        rebuildContent()
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    private func setupUI() {
        let secLabel = NSTextField(labelWithString: "DICTATIONS")
        secLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        secLabel.textColor = Theme.text3
        secLabel.translatesAutoresizingMaskIntoConstraints = false

        contentStack = FlippedView()
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        emptyView = makeEmptyState()
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = contentStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(secLabel)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            secLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            secLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scrollView.topAnchor.constraint(equalTo: secLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    func addEntry(text: String, time: String) {
        entries.insert(HistoryEntry(text: text, time: time), at: 0)
        if entries.count > storeCap { entries = Array(entries.prefix(storeCap)) }
        DictationsView.saveEntries(entries)
        rebuildContent()
    }

    private func rebuildContent() {
        contentStack.subviews.forEach { $0.removeFromSuperview() }

        if entries.isEmpty {
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

        // Cards (newest first, capped)
        let capped = Array(entries.prefix(renderCap))
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
        if let card = sender.superview as? HoverCardView {
            card.layer?.backgroundColor = NSColor(r: 120, g: 180, b: 100, a: 15).cgColor
            card.layer?.borderColor = NSColor(r: 120, g: 180, b: 100, a: 30).cgColor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                card.layer?.backgroundColor = Theme.card.cgColor
                card.layer?.borderColor = Theme.border.cgColor
            }
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

        let h = NSTextField(labelWithString: "Your dictations will appear here")
        h.font = .systemFont(ofSize: 12)
        h.textColor = Theme.text3
        h.alignment = .center
        v.addArrangedSubview(h)

        return v
    }

    // ── Persistence ────────────────────────────────────

    /// Newest-first dictations straight from the store (used by the MCP
    /// get_recent_dictations tool — no UI involved).
    static func recentEntries(limit: Int) -> [HistoryEntry] {
        Array(loadEntries().prefix(max(0, limit)))
    }

    private static func loadEntries() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return [] }
        return list
    }

    private static func saveEntries(_ entries: [HistoryEntry]) {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Text-to-Speech view — paste text and play it
//  Hosted as a tab inside ChatPanel; drives the shared TTS engine.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class TTSView: NSView {
    var onSpeak: ((TTSRequest) -> Void)?
    var onSeek: ((Double) -> Void)?
    var onStop: (() -> Void)?

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupUI()
        updateTTSSpeedLabel()
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    private func setupUI() {
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

        addSubview(ttsHeader)
        addSubview(controlsRow)
        addSubview(ttsServerLabel)
        addSubview(textScroll)

        NSLayoutConstraint.activate([
            ttsHeader.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            ttsHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            ttsHeader.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            controlsRow.topAnchor.constraint(equalTo: ttsHeader.bottomAnchor, constant: 12),
            controlsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            controlsRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            ttsServerLabel.topAnchor.constraint(equalTo: controlsRow.bottomAnchor, constant: 12),
            ttsServerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            ttsServerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            textScroll.topAnchor.constraint(equalTo: ttsServerLabel.bottomAnchor, constant: 10),
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    private func gridLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text2
        return label
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
        onSeek?(ttsTimelineSlider?.doubleValue ?? 0)
    }

    @objc private func ttsSpeakClicked() {
        onSpeak?(currentTTSRequest())
    }

    @objc private func ttsStopClicked() {
        onStop?()
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
        // Park the global hotkeys: they must neither fire nor swallow the
        // keys the user is trying to record.
        HotkeyManager.isCapturingHotkey = true
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
        HotkeyManager.isCapturingHotkey = false
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
