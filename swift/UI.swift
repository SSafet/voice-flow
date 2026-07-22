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
    var onToggleWatcher: (() -> Void)?
    var onRunReview: (() -> Void)?
    var onOpenLatestReview: (() -> Void)?
    var onOpenWatcherFolder: (() -> Void)?
    /// Live one-liner for the watcher submenu, rebuilt every time it opens
    /// (e.g. "Watching — 71 frames today").
    var watcherStatusProvider: (() -> String)?
    var onCopyCapturePrompt: (() -> Void)?
    var onToggleAnnotate: (() -> Void)?
    var onShowChat: (() -> Void)?
    var onPairPhone: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Connected Claude Code sessions for the "Voice Goes To" submenu,
    /// rebuilt every time it opens.
    var claudeSessionsProvider: (() -> [(id: String, title: String, isTarget: Bool)])?
    var onSelectClaudeSession: ((String) -> Void)?
    /// Pending inbox messages, shown live on the copy-queued-messages item.
    var inboxCountProvider: (() -> Int)?
    var onCopyInbox: (() -> Void)?

    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var sessionMenuItem: NSMenuItem!
    private var watcherMenu: NSMenu!
    private var watcherStatusItem: NSMenuItem!
    private var watcherToggleItem: NSMenuItem!
    private var claudeSessionsMenu: NSMenu!
    private var mainMenu: NSMenu!
    private var inboxMenuItem: NSMenuItem!

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
        sessionMenuItem = menu.addItem(withTitle: "Start Continuous Capture", action: #selector(toggleSessionAction), keyEquivalent: "")
        sessionMenuItem.target = self
        let watcherRootItem = menu.addItem(withTitle: "Workflow Watcher", action: nil, keyEquivalent: "")
        watcherMenu = NSMenu(title: "Workflow Watcher")
        watcherMenu.delegate = self
        watcherStatusItem = watcherMenu.addItem(withTitle: "Off", action: nil, keyEquivalent: "")
        watcherStatusItem.isEnabled = false
        watcherToggleItem = watcherMenu.addItem(withTitle: "Watch Workflow", action: #selector(toggleWatcherAction), keyEquivalent: "")
        watcherToggleItem.target = self
        watcherMenu.addItem(.separator())
        watcherMenu.addItem(withTitle: "Run Review Now", action: #selector(runReviewAction), keyEquivalent: "").target = self
        watcherMenu.addItem(withTitle: "Open Latest Review", action: #selector(openLatestReviewAction), keyEquivalent: "").target = self
        watcherMenu.addItem(withTitle: "Open Data Folder", action: #selector(openWatcherFolderAction), keyEquivalent: "").target = self
        menu.setSubmenu(watcherMenu, for: watcherRootItem)
        menu.addItem(withTitle: "Copy Prompt for Latest Capture", action: #selector(copyCaptureAction), keyEquivalent: "").target = self
        inboxMenuItem = menu.addItem(withTitle: "No Queued Messages for Claude", action: nil, keyEquivalent: "")
        let voiceTargetItem = menu.addItem(withTitle: "Voice Goes To", action: nil, keyEquivalent: "")
        claudeSessionsMenu = NSMenu(title: "Voice Goes To")
        claudeSessionsMenu.delegate = self
        menu.setSubmenu(claudeSessionsMenu, for: voiceTargetItem)
        menu.addItem(withTitle: "Annotate Screen", action: #selector(annotateAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show Chat", action: #selector(chatAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Dictation History", action: #selector(historyAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Pair Phone", action: #selector(pairPhoneAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(permissionsAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(settingsAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Flow", action: #selector(quitAction), keyEquivalent: "").target = self
        menu.delegate = self
        mainMenu = menu
        statusItem.menu = menu
    }

    func setState(_ state: AppState) {
        statusMenuItem?.title = "Voice Flow — \(Theme.stateLabel(state))"
    }

    func setSessionActive(_ active: Bool) {
        sessionMenuItem?.title = active ? "End Continuous Capture" : "Start Continuous Capture"
        sessionMenuItem?.state = active ? .on : .off
    }

    func setWatcherActive(_ active: Bool) {
        watcherToggleItem?.state = active ? .on : .off
    }

    @objc private func historyAction() { onShowHistory?() }
    @objc private func permissionsAction() { onShowPermissions?() }
    @objc private func pairPhoneAction() { onPairPhone?() }
    @objc private func settingsAction() { onShowSettings?() }
    @objc private func toggleSessionAction() { onToggleSession?() }
    @objc private func toggleWatcherAction() { onToggleWatcher?() }
    @objc private func runReviewAction() { onRunReview?() }
    @objc private func openLatestReviewAction() { onOpenLatestReview?() }
    @objc private func openWatcherFolderAction() { onOpenWatcherFolder?() }
    @objc private func copyCaptureAction() { onCopyCapturePrompt?() }
    @objc private func copyInboxAction() { onCopyInbox?() }
    @objc private func annotateAction() { onToggleAnnotate?() }
    @objc private func chatAction() { onShowChat?() }
    @objc private func quitAction() { onQuit?() }
    @objc private func selectClaudeSessionAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectClaudeSession?(id)
    }
}

extension MenuBarManager: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === mainMenu {
            let count = inboxCountProvider?() ?? 0
            if count > 0 {
                inboxMenuItem.title = "Copy \(count) Queued Message\(count == 1 ? "" : "s") for Claude"
                inboxMenuItem.action = #selector(copyInboxAction)
                inboxMenuItem.target = self
            } else {
                inboxMenuItem.title = "No Queued Messages for Claude"
                inboxMenuItem.action = nil
                inboxMenuItem.target = nil
            }
            return
        }
        if menu === watcherMenu {
            watcherStatusItem.title = watcherStatusProvider?() ?? "Off"
            return
        }
        guard menu === claudeSessionsMenu else { return }
        menu.removeAllItems()
        let sessions = claudeSessionsProvider?() ?? []
        guard !sessions.isEmpty else {
            let empty = menu.addItem(withTitle: "No Claude Code sessions connected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return
        }
        for session in sessions {
            let item = menu.addItem(withTitle: session.title,
                                    action: #selector(selectClaudeSessionAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            item.state = session.isTarget ? .on : .off
        }
    }
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
    var onToggleWatcher: (() -> Void)?
    /// Context-menu session removal: the list to offer, and the action.
    var onSessionRemovals: (() -> [(id: String, label: String)])?
    var onRemoveSession: ((String) -> Void)?

    private let W: CGFloat = 52, H: CGFloat = 18
    private let DOT_R: CGFloat = 3, DOT_SP: CGFloat = 11

    private var panel: NSPanel!
    /// Holds the whole classic pill (background, rings, dots) so the panel
    /// can grow around it without touching any dot animation.
    private var capsuleLayer: CALayer!
    private var pillLayer: CALayer!
    private var sessionRingLayer: CALayer!
    private var watcherRingLayer: CALayer!
    private var dotLayers: [CALayer] = []
    // Flash mode: the pill stretches into one wide capsule, the dots swap
    // out for the session title on a single line, 5s later it shrinks back.
    private var expandTitleLayer: CATextLayer!
    private var middleDigitLayer: CATextLayer!
    private var unreadRingLayer: CALayer!
    private var pickerLayer: CALayer?
    private var expandTimer: Timer?
    /// Set when an action pauses a preview's auto-hide (revertGrownBandToDots);
    /// the hide re-arms once the state returns to idle.
    private var resumeAutoHideOnIdle = false
    private var expandedSize: NSSize?
    private var activeNumber: Int?
    private var clickMonitor: Any?

    /// What the surface currently is. flash/picker are transient (timer,
    /// click-anywhere, or another hotkey collapse them); grown content
    /// persists until ✕/trash or an explicit hide.
    private enum SurfaceMode { case pill, flash, picker, grown }
    private var mode: SurfaceMode = .pill
    /// Bumped on every transition — in-flight animation completions check
    /// it so a new expand can't be clobbered by a stale collapse.
    private var transitionGeneration = 0

    /// Window frames snap instantly while layers animate implicitly — do
    /// layout in here so both worlds agree, then animate deliberately.
    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
    var isGrownVisible: Bool { mode == .grown }
    /// Exact geometry consumed by ChatPanel. The screen is resolved from the
    /// pill window itself, never independently from display ordering.
    var panelAnchor: PanelAnchor? {
        guard let panel else { return nil }
        let screen = panel.screen ?? NSScreen.screens.first {
            $0.frame.intersects(panel.frame)
        }
        guard let screen else { return nil }
        return PanelAnchor(frame: panel.frame, visibleFrame: screen.visibleFrame)
    }

    // Grown mode — message content above, live dots at the bottom band.
    struct GrownSpec {
        var title: String?
        var text: String
        /// Older queued pushes from the same session, oldest first —
        /// rendered dim above the newest message so a second push stacks
        /// instead of replacing what the user hasn't read yet.
        var earlier: [String] = []
        var hint: String?
        var isAsk = false
    }
    var onGrownSpeak: ((String) -> Void)?
    var onGrownTrash: (() -> Void)?
    var onGrownClose: (() -> Void)?
    private var grownBackdropLayer: CALayer!
    private var grownStatusLabel: NSTextField!
    private var grownHintLabel: NSTextField!
    private var grownScroll: NSScrollView!
    private var grownTextView: NSTextView!
    private var iconSpeaker: NSButton!
    private var iconTrash: NSButton!
    private var iconClose: NSButton!
    private var grownStreaming = false
    private let grownWidth: CGFloat = 400
    private let grownMaxTextHeight: CGFloat = 320

    private var state: AppState = .idle
    private var sessionActive = false
    private var watcherActive = false
    private var agentActivity: AgentActivity = .idle
    private var ttsSnapshot: TTSStatusSnapshot?
    private var recordingCapability: CaptureCapability = .dictate
    private var appliedVisual: Visual?
    private var appliedRing: (session: Bool, watcher: Bool)?

    /// While the reply bubble is visible the pill docks right above it —
    /// the real pill, animations and all, visually attached to the bubble.
    private var dockFrame: NSRect?

    /// Current panel size — the classic pill, or the expanded shell.
    private var panelSize: NSSize { expandedSize ?? NSSize(width: W, height: H) }

    /// The reply bubble grows upward from the pill's home spot; the pill
    /// docks INTO its bottom edge — the exact screen position it always
    /// has — floating above the bubble so the dots stay visible inside it.
    func dock(into bubbleFrame: NSRect) {
        dockFrame = bubbleFrame
        guard let panel else { return }
        let size = panelSize
        let x = (bubbleFrame.midX - size.width / 2).rounded()
        let y = (bubbleFrame.minY + 3).rounded()
        panel.level = .floating + 2
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.orderFront(nil)
    }

    func undock() {
        dockFrame = nil
        panel?.level = .floating
        recenter()
    }

    // ── Session UI in the pill ──────────────────────────

    /// One entry per available session for the picker row.
    struct PickerEntry {
        let number: Int
        let active: Bool
        let pending: Bool
    }

    /// The middle dot grows a touch and carries the active session's
    /// number; nil (no sessions) restores the classic dot.
    func setActiveSessionNumber(_ number: Int?) {
        activeNumber = number
        guard dotLayers.count == 3, let digit = middleDigitLayer else { return }
        let cx = W / 2.0, cy = H / 2.0
        if let number {
            dotLayers[1].frame = CGRect(x: cx - 4.5, y: cy - 4.5, width: 9, height: 9)
            dotLayers[1].cornerRadius = 4.5
            digit.string = "\(number)"
            digit.frame = CGRect(x: 0, y: 1, width: 9, height: 8)
            digit.isHidden = false
        } else {
            dotLayers[1].frame = CGRect(x: cx - DOT_R, y: cy - DOT_R, width: DOT_R * 2, height: DOT_R * 2)
            dotLayers[1].cornerRadius = DOT_R
            digit.isHidden = true
        }
        layoutUnreadRing()
    }

    /// Small pulsing halo around the middle dot — "something unread in a
    /// session you're not on". Deliberately tiny; the picker's amber dots
    /// carry the detail.
    func setUnreadIndicator(_ on: Bool) {
        guard unreadRingLayer != nil else { return }
        withoutAnimation {
            layoutUnreadRing()
            unreadRingLayer.isHidden = !on
        }
        if on { ensureUnreadPulse() }
    }

    /// Sleep/wake and display changes silently kill CA animations; re-add
    /// the ring's pulse whenever it might have been dropped.
    private func ensureUnreadPulse() {
        guard let ring = unreadRingLayer, ring.animation(forKey: "unreadPulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.2
        pulse.toValue = 0.95
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        ring.add(pulse, forKey: "unreadPulse")
    }

    private func layoutUnreadRing() {
        guard let ring = unreadRingLayer, dotLayers.count == 3 else { return }
        // Exactly the dot's own size — the ring reads as the dot's edge
        // pulsing amber, not a halo floating around it.
        let ringRect = dotLayers[1].bounds
        ring.frame = ringRect
        ring.cornerRadius = ringRect.width / 2
    }

    /// The session picker: the pill stretches into one line — "sessions",
    /// a numbered dot per available session (active lit, pending amber),
    /// the active session's name trailing. Collapses after `seconds`, on
    /// any other hotkey, or on a click anywhere.
    func showPicker(entries: [PickerEntry], activeName: String?, seconds: TimeInterval = 4.0) {
        guard panel != nil else { return }
        guard !entries.isEmpty else {
            flashMessage("no sessions — click me for Messages")
            return
        }
        expandTimer?.invalidate()
        pickerLayer?.removeFromSuperlayer()
        expandTitleLayer.isHidden = true

        let shellH = H + 8
        let shellW = pickerRowWidth(entries: entries, activeName: activeName)
        expandShell(width: shellW, height: shellH, as: .picker)

        let row = buildPickerRow(entries: entries, activeName: activeName, shellW: shellW, shellH: shellH)
        capsuleLayer.addSublayer(row)
        pickerLayer = row

        expandTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.collapseNow()
        }
    }

    private func pickerRowWidth(entries: [PickerEntry], activeName: String?) -> CGFloat {
        let labelFont = NSFont.systemFont(ofSize: 10.5)
        let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let labelW = ceil(("sessions" as NSString).size(withAttributes: [.font: labelFont]).width)
        let name = activeName ?? ""
        let nameW = name.isEmpty ? 0 : min(220, ceil((name as NSString).size(withAttributes: [.font: nameFont]).width))
        let dotsW = CGFloat(entries.count) * 12 + CGFloat(max(0, entries.count - 1)) * 6
        return max(W, min(440, 14 + labelW + 10 + dotsW + (nameW > 0 ? 10 + nameW : 0) + 14))
    }

    private func buildPickerRow(entries: [PickerEntry], activeName: String?, shellW: CGFloat, shellH: CGFloat) -> CALayer {
        let labelFont = NSFont.systemFont(ofSize: 10.5)
        let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let labelW = ceil(("sessions" as NSString).size(withAttributes: [.font: labelFont]).width)
        let name = activeName ?? ""

        let row = CALayer()
        row.frame = CGRect(x: 0, y: 0, width: shellW, height: shellH)
        var x: CGFloat = 14

        let label = CATextLayer()
        label.string = "sessions"
        label.font = labelFont
        label.fontSize = 10.5
        label.foregroundColor = NSColor(r: 168, g: 158, b: 141).cgColor
        label.contentsScale = 2
        label.frame = CGRect(x: x, y: (shellH - 13) / 2, width: labelW + 2, height: 13)
        row.addSublayer(label)
        x += labelW + 10

        for entry in entries {
            let dot = makeSessionDot(entry)
            dot.frame.origin = CGPoint(x: x, y: (shellH - 12) / 2)
            row.addSublayer(dot)
            x += 18
        }

        if !name.isEmpty {
            let nameLayer = CATextLayer()
            nameLayer.string = name
            nameLayer.font = nameFont
            nameLayer.fontSize = 11.5
            nameLayer.truncationMode = .end
            nameLayer.foregroundColor = Theme.text.cgColor
            nameLayer.contentsScale = 2
            nameLayer.frame = CGRect(x: x + 4, y: (shellH - 14) / 2, width: shellW - x - 18, height: 14)
            row.addSublayer(nameLayer)
        }
        return row
    }

    /// One numbered session dot (active lit, pending amber) — shared by
    /// the one-line picker row and the grown band.
    private func makeSessionDot(_ entry: PickerEntry) -> CALayer {
        let dot = CALayer()
        dot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        dot.cornerRadius = 6
        let digit = CATextLayer()
        digit.string = "\(entry.number)"
        digit.font = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        digit.fontSize = 7.5
        digit.alignmentMode = .center
        digit.contentsScale = 2
        digit.frame = CGRect(x: 0, y: 1.5, width: 12, height: 9)
        if entry.active {
            dot.backgroundColor = NSColor(r: 216, g: 207, b: 192).cgColor
            digit.foregroundColor = NSColor(r: 23, g: 21, b: 15).cgColor
        } else if entry.pending {
            dot.borderWidth = 1
            dot.borderColor = NSColor(r: 255, g: 194, b: 75, a: 217).cgColor
            digit.foregroundColor = NSColor(r: 255, g: 194, b: 75).cgColor
        } else {
            dot.borderWidth = 1
            dot.borderColor = NSColor(r: 111, g: 103, b: 92).cgColor
            digit.foregroundColor = NSColor(r: 168, g: 158, b: 141).cgColor
        }
        dot.addSublayer(digit)
        return dot
    }

    /// The grown band's session row: JUST the numbered dots, centered —
    /// the session title already sits at the top of the container.
    private func buildGrownSessionDots(entries: [PickerEntry], width: CGFloat, bandH: CGFloat) -> CALayer {
        let row = CALayer()
        row.frame = CGRect(x: 0, y: 0, width: width, height: bandH)
        let total = CGFloat(entries.count) * 12 + CGFloat(max(0, entries.count - 1)) * 6
        var x = (width - total) / 2
        for entry in entries {
            let dot = makeSessionDot(entry)
            dot.frame.origin = CGPoint(x: x, y: (bandH - 12) / 2)
            row.addSublayer(dot)
            x += 18
        }
        return row
    }

    /// The moment an action starts (recording, transcribing) the session
    /// row in the grown band steps aside: the selection is decided, the
    /// three live dots return to their centered spot and carry the
    /// activity animation. The grown container itself stays put.
    private func revertGrownBandToDots() {
        guard mode == .grown, pickerLayer != nil, let size = expandedSize else { return }
        // A seen-stack preview carries a 5s auto-hide; pause it while the
        // user acts and re-arm it when the state settles back to idle —
        // otherwise the "preview" outlives its welcome forever.
        resumeAutoHideOnIdle = expandTimer != nil
        expandTimer?.invalidate()
        expandTimer = nil
        pickerLayer?.removeFromSuperlayer()
        pickerLayer = nil
        withoutAnimation {
            capsuleLayer.frame = CGRect(x: (size.width - W) / 2, y: 3, width: W, height: H)
            dotLayers.forEach { $0.isHidden = false }
        }
        applyState(force: true)
    }

    /// Short in-pill feedback ("no sessions", receipts) — one-line stretch.
    func flashMessage(_ text: String, seconds: TimeInterval = 2.0, isError: Bool = false) {
        guard panel != nil else { return }
        expandTimer?.invalidate()
        pickerLayer?.removeFromSuperlayer()
        pickerLayer = nil

        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        let shellW = max(W, min(340, textWidth + 30))
        let shellH = H + 6
        expandShell(width: shellW, height: shellH, as: .flash)

        withoutAnimation {
            expandTitleLayer.font = font
            expandTitleLayer.fontSize = 11.5
            expandTitleLayer.foregroundColor = isError
                ? NSColor(r: 255, g: 138, b: 138).cgColor
                : Theme.text.cgColor
            expandTitleLayer.string = text
            expandTitleLayer.frame = CGRect(x: 15, y: (shellH - 14) / 2, width: shellW - 30, height: 14)
            expandTitleLayer.isHidden = false
        }

        expandTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.collapseNow()
        }
    }

    /// Stretch the one-line shell around the capsule, hiding the classic dots.
    /// The window snaps to the target size instantly; the capsule is re-seeded
    /// at its current visual spot in the new coordinates and then animates —
    /// so nothing gets clipped or flies in from a stale corner.
    private func expandShell(width shellW: CGFloat, height shellH: CGFloat, as newMode: SurfaceMode) {
        transitionGeneration += 1
        let previousWindowW = panelSize.width
        let previousCapsule = capsuleLayer.frame
        mode = newMode
        expandedSize = NSSize(width: shellW, height: shellH)
        recenter()

        withoutAnimation {
            // Same screen position, expressed in the new window's coords.
            let seedX = (shellW - previousWindowW) / 2 + previousCapsule.origin.x
            capsuleLayer.frame = CGRect(x: seedX, y: previousCapsule.origin.y,
                                        width: previousCapsule.width, height: previousCapsule.height)
            grownBackdropLayer.isHidden = true
            hideGrownChrome()
            dotLayers.forEach { $0.isHidden = true }
            pillLayer.isHidden = false
            sessionRingLayer.isHidden = false
            watcherRingLayer.isHidden = false
        }

        // Deliberate morph to the stretched shell.
        capsuleLayer.frame = CGRect(x: 0, y: 0, width: shellW, height: shellH)
        pillLayer.frame = CGRect(x: 1, y: 1, width: shellW - 2, height: shellH - 2)
        pillLayer.cornerRadius = (shellH - 2) / 2
        sessionRingLayer.frame = CGRect(x: 0, y: 0, width: shellW, height: shellH)
        sessionRingLayer.cornerRadius = shellH / 2
        watcherRingLayer.frame = CGRect(x: 0, y: 0, width: shellW, height: shellH)
        watcherRingLayer.cornerRadius = shellH / 2

        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.collapseNow()
            }
        }
    }

    /// Collapse transient surfaces (flash / picker) — timer, click-anywhere,
    /// or another hotkey. Grown content persists; hide it via hideGrown().
    func collapseNow() {
        guard mode == .flash || mode == .picker else { return }
        collapseToPill()
    }

    /// Dismiss grown content (✕ / trash / programmatic).
    func hideGrown() {
        guard mode == .grown else { return }
        grownStreaming = false
        collapseToPill()
    }

    private func collapseToPill() {
        transitionGeneration += 1
        let generation = transitionGeneration
        let wasExpanded = expandedSize
        mode = .pill
        expandTimer?.invalidate()
        expandTimer = nil
        resumeAutoHideOnIdle = false
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }

        // Phase 1 — while the window is still large, shrink everything back
        // to a pill CENTERED in it (same screen spot the small window will
        // occupy), fading the expanded chrome. Snapping the window first
        // would clip the animation mid-flight.
        hideGrownChrome()
        expandTitleLayer.isHidden = true
        grownBackdropLayer.isHidden = true
        pickerLayer?.removeFromSuperlayer()
        pickerLayer = nil

        let windowW = wasExpanded?.width ?? W
        pillLayer.isHidden = false
        capsuleLayer.frame = CGRect(x: (windowW - W) / 2, y: 0, width: W, height: H)
        pillLayer.frame = CGRect(x: 1, y: 1, width: W - 2, height: H - 2)
        pillLayer.cornerRadius = (H - 2) / 2
        sessionRingLayer.isHidden = false
        watcherRingLayer.isHidden = false
        sessionRingLayer.frame = CGRect(x: 0, y: 0, width: W, height: H)
        sessionRingLayer.cornerRadius = H / 2
        watcherRingLayer.frame = CGRect(x: 0, y: 0, width: W, height: H)
        watcherRingLayer.cornerRadius = H / 2
        dotLayers.forEach { $0.isHidden = false }

        // Phase 2 — after the shrink lands, snap the window to pill size and
        // re-anchor the capsule at the origin (same screen position).
        let finish = { [weak self] in
            guard let self, self.transitionGeneration == generation else { return }
            self.expandedSize = nil
            self.withoutAnimation {
                self.capsuleLayer.frame = CGRect(x: 0, y: 0, width: self.W, height: self.H)
            }
            self.recenter()
            self.applyState(force: true)
        }
        if wasExpanded == nil {
            finish()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: finish)
        }
    }

    // ── Grown mode: message content above, live dots at the bottom ──

    private func hideGrownChrome() {
        grownStatusLabel?.isHidden = true
        grownHintLabel?.isHidden = true
        grownScroll?.isHidden = true
        iconSpeaker?.isHidden = true
        iconTrash?.isHidden = true
        iconClose?.isHidden = true
    }

    /// Show content grown out of the pill: title/text/hint above, the live
    /// dots (still animating, with the session number) in the bottom band.
    /// Persists until ✕/trash/hideGrown, unless `autoHide` is set. Pass
    /// `bottomPicker` to render the session picker row instead of the dots
    /// (used while switching sessions with a message to preview).
    func showGrown(_ spec: GrownSpec,
                   bottomPicker: (entries: [PickerEntry], activeName: String?)? = nil,
                   autoHide: TimeInterval? = nil) {
        guard panel != nil else { return }
        expandTimer?.invalidate()
        expandTimer = nil
        pickerLayer?.removeFromSuperlayer()
        pickerLayer = nil
        expandTitleLayer.isHidden = true
        grownStreaming = false
        resumeAutoHideOnIdle = false

        let entering = mode != .grown
        // Remember where the surface visually is, to grow out of it.
        let previousWindowW = panelSize.width
        let previousCapsule = capsuleLayer.frame
        mode = .grown
        transitionGeneration += 1

        grownStatusLabel.stringValue = spec.title ?? ""
        grownHintLabel.stringValue = spec.hint ?? ""
        let body = NSMutableAttributedString()
        for older in spec.earlier {
            body.append(NSAttributedString(
                string: older + "\n\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text2]))
        }
        body.append(NSAttributedString(
            string: spec.text,
            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text]))
        grownTextView.textStorage?.setAttributedString(body)
        withoutAnimation {
            grownBackdropLayer.borderColor = spec.isAsk
                ? NSColor(r: 255, g: 194, b: 75, a: 217).cgColor
                : NSColor(r: 255, g: 170, b: 60, a: 140).cgColor
        }
        relayoutGrown(bottomPicker: bottomPicker,
                      enteringFrom: entering ? (previousWindowW, previousCapsule) : nil)
        // A stack taller than the window should open at its newest entry.
        if !spec.earlier.isEmpty {
            grownTextView.scrollToEndOfDocument(nil)
        }

        if let autoHide {
            expandTimer = Timer.scheduledTimer(withTimeInterval: autoHide, repeats: false) { [weak self] _ in
                self?.hideGrown()
            }
        }
    }

    /// Streamed replies: open empty, append deltas, finish with full text.
    func beginGrownStream(title: String?) {
        showGrown(GrownSpec(title: title ?? "Replying…", text: ""))
        grownStreaming = true
    }

    func appendGrownDelta(_ delta: String) {
        guard mode == .grown, grownStreaming else { return }
        grownTextView.textStorage?.append(NSAttributedString(
            string: delta,
            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text]))
        relayoutGrown(bottomPicker: nil)
        grownTextView.scrollToEndOfDocument(nil)
    }

    func finishGrownStream(_ fullText: String, title: String?) {
        // Without the streaming guard, a reply finishing AFTER the user
        // switched to a push stack would overwrite the stack's text.
        guard mode == .grown, grownStreaming else { return }
        grownStreaming = false
        grownStatusLabel.stringValue = title ?? ""
        grownTextView.textStorage?.setAttributedString(NSAttributedString(
            string: fullText,
            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Theme.text]))
        relayoutGrown(bottomPicker: nil)
    }

    /// Lay out grown mode. `enteringFrom` (previous window width + capsule
    /// frame) seeds a grow-out-of-the-pill morph; nil relayouts (streaming
    /// deltas) apply instantly so nothing animates from stale frames.
    private func relayoutGrown(bottomPicker: (entries: [PickerEntry], activeName: String?)?,
                               enteringFrom seed: (windowW: CGFloat, capsule: CGRect)? = nil) {
        guard mode == .grown, let container = grownTextView.textContainer,
              let layoutManager = grownTextView.layoutManager else { return }

        let width = grownWidth
        let hasTitle = !grownStatusLabel.stringValue.isEmpty
        let hasHint = !grownHintLabel.stringValue.isEmpty
        let bottomBand: CGFloat = 26

        withoutAnimation {
            grownScroll.frame.size.width = width - 24
            grownTextView.frame.size.width = width - 24
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height
        let textHeight = min(max(used + 6, 22), grownMaxTextHeight)

        let titleSpace: CGFloat = hasTitle ? 24 : 6
        let hintSpace: CGFloat = hasHint ? 20 : 0
        let totalH = 8 + titleSpace + textHeight + hintSpace + bottomBand
        expandedSize = NSSize(width: width, height: totalH)
        recenter()

        if let seed {
            // Seed the backdrop at the pill's current visual rect (in the
            // new window's coordinates) so the container grows out of it.
            withoutAnimation {
                let seedX = (width - seed.windowW) / 2 + seed.capsule.origin.x
                let seedRect = CGRect(x: seedX, y: seed.capsule.origin.y,
                                      width: seed.capsule.width, height: seed.capsule.height)
                grownBackdropLayer.isHidden = false
                grownBackdropLayer.frame = seedRect
                grownBackdropLayer.cornerRadius = seed.capsule.height / 2
                capsuleLayer.frame = seedRect
            }
        }

        let layout = {
            self.grownBackdropLayer.isHidden = false
            self.grownBackdropLayer.frame = CGRect(x: 0, y: 0, width: width, height: totalH)
            self.grownBackdropLayer.cornerRadius = 14

            // Bottom band: naked capsule dots (skin hidden) or the picker row.
            self.pillLayer.isHidden = true
            self.sessionRingLayer.isHidden = true
            self.watcherRingLayer.isHidden = true
            self.pickerLayer?.removeFromSuperlayer()
            self.pickerLayer = nil
            if let bottomPicker {
                self.dotLayers.forEach { $0.isHidden = true }
                self.capsuleLayer.frame = CGRect(x: 0, y: 0, width: width, height: bottomBand)
                let row = self.buildGrownSessionDots(entries: bottomPicker.entries,
                                                     width: width, bandH: bottomBand)
                self.capsuleLayer.addSublayer(row)
                self.pickerLayer = row
            } else {
                self.dotLayers.forEach { $0.isHidden = false }
                self.capsuleLayer.frame = CGRect(x: (width - self.W) / 2, y: 3, width: self.W, height: self.H)
            }
        }
        if seed != nil {
            layout()   // implicit animation from the seeded rects
        } else {
            withoutAnimation(layout)
        }

        // Content views (panel coords, bottom-up); fade in on entry.
        grownScroll.isHidden = false
        grownScroll.frame = NSRect(x: 12, y: bottomBand + hintSpace, width: width - 24, height: textHeight)
        grownHintLabel.isHidden = !hasHint
        if hasHint {
            grownHintLabel.frame = NSRect(x: 12, y: bottomBand + 2, width: width - 24, height: 15)
        }
        grownStatusLabel.isHidden = !hasTitle
        if hasTitle {
            grownStatusLabel.frame = NSRect(x: 12, y: totalH - 24, width: width - 100, height: 16)
        }
        iconClose.isHidden = false
        iconClose.frame = NSRect(x: width - 26, y: totalH - 24, width: 16, height: 16)
        iconTrash.isHidden = false
        iconTrash.frame = NSRect(x: width - 48, y: totalH - 24, width: 16, height: 16)
        iconSpeaker.isHidden = false
        iconSpeaker.frame = NSRect(x: width - 70, y: totalH - 24, width: 16, height: 16)
        if seed != nil {
            for view in [grownScroll, grownHintLabel, grownStatusLabel, iconClose, iconTrash, iconSpeaker] as [NSView] {
                view.alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                for view in [grownScroll, grownHintLabel, grownStatusLabel, iconClose, iconTrash, iconSpeaker] as [NSView] {
                    view.animator().alphaValue = 1
                }
            }
        }
    }

    @objc private func grownSpeakTapped() {
        onGrownSpeak?(grownTextView.string)
    }

    @objc private func grownTrashTapped() {
        onGrownTrash?()
        hideGrown()
    }

    @objc private func grownCloseTapped() {
        onGrownClose?()
        hideGrown()
    }

    func show() {
        // KeyablePanel: grown content hosts a scrollable text view, and
        // borderless windows otherwise refuse the key status scrolling needs.
        panel = KeyablePanel(
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
        rootView.onClick = { [weak self] in
            guard let self else { return }
            // Grown content (a session's stack) stays a pill-flow surface:
            // clicking its padding puts it away like ✕ (stack kept) and
            // NEVER yanks the user into the panel (Safet QA, ticket #15).
            // A collapsed pill / receipt / picker click still opens the app.
            if self.isGrownVisible {
                self.collapseNow()
                return
            }
            self.collapseNow()
            self.onClick?()
        }
        rootView.onRightClick = { [weak self] view, point in self?.showContextMenu(in: view, at: point) }
        rootView.wantsLayer = true
        rootView.autoresizingMask = [.width, .height]
        let root = rootView.layer!

        // Grown-mode backdrop — the whole shape when content is showing.
        grownBackdropLayer = CALayer()
        grownBackdropLayer.backgroundColor = NSColor(r: 33, g: 30, b: 27, a: 245).cgColor
        grownBackdropLayer.borderColor = NSColor(r: 255, g: 170, b: 60, a: 140).cgColor
        grownBackdropLayer.borderWidth = 1
        grownBackdropLayer.cornerRadius = 14
        grownBackdropLayer.isHidden = true
        root.addSublayer(grownBackdropLayer)

        // Everything that IS the classic pill lives in one capsule layer, so
        // the panel can grow around it without touching the dot animations.
        capsuleLayer = CALayer()
        capsuleLayer.frame = CGRect(x: 0, y: 0, width: W, height: H)
        root.addSublayer(capsuleLayer)

        // Pill background — inset by 1pt so the session ring has room.
        pillLayer = CALayer()
        pillLayer.frame = CGRect(x: 1, y: 1, width: W - 2, height: H - 2)
        pillLayer.cornerRadius = (H - 2) / 2
        pillLayer.borderWidth = 1.0
        capsuleLayer.addSublayer(pillLayer)

        // Watcher ring — a faint static amber outline while the ambient
        // workflow watcher records. Sits under the session ring, which
        // covers it whenever a session is live.
        watcherRingLayer = CALayer()
        watcherRingLayer.frame = CGRect(x: 0, y: 0, width: W, height: H)
        watcherRingLayer.cornerRadius = H / 2
        watcherRingLayer.backgroundColor = NSColor.clear.cgColor
        watcherRingLayer.borderColor = NSColor(r: 255, g: 170, b: 60, a: 110).cgColor
        watcherRingLayer.borderWidth = 1.0
        watcherRingLayer.opacity = 0
        capsuleLayer.addSublayer(watcherRingLayer)

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
        capsuleLayer.addSublayer(sessionRingLayer)

        // 3 dots, centered as a group on the pill
        let cy = H / 2.0
        let firstDotX = W / 2.0 - DOT_SP
        for i in 0..<3 {
            let dot = CALayer()
            let x = firstDotX + CGFloat(i) * DOT_SP
            dot.frame = CGRect(x: x - DOT_R, y: cy - DOT_R, width: DOT_R * 2, height: DOT_R * 2)
            dot.cornerRadius = DOT_R
            capsuleLayer.addSublayer(dot)
            dotLayers.append(dot)
        }

        // The active session's number, carried inside the middle dot
        // (which setActiveSessionNumber grows to 9px while it's shown).
        middleDigitLayer = CATextLayer()
        middleDigitLayer.alignmentMode = .center
        middleDigitLayer.contentsScale = 2
        middleDigitLayer.fontSize = 6.5
        middleDigitLayer.font = NSFont.systemFont(ofSize: 6.5, weight: .bold)
        middleDigitLayer.foregroundColor = NSColor(r: 23, g: 21, b: 15).cgColor
        middleDigitLayer.frame = CGRect(x: 0, y: 1, width: 9, height: 8)
        middleDigitLayer.isHidden = true
        dotLayers[1].addSublayer(middleDigitLayer)

        // Unread ring — a small pulsing halo around the middle dot while a
        // session the user is NOT on holds pushes they haven't seen. Rides
        // the dot as a sublayer so it follows every mode and animation.
        unreadRingLayer = CALayer()
        unreadRingLayer.backgroundColor = NSColor.clear.cgColor
        unreadRingLayer.borderColor = NSColor(r: 255, g: 194, b: 75, a: 217).cgColor
        unreadRingLayer.borderWidth = 1
        unreadRingLayer.isHidden = true
        dotLayers[1].addSublayer(unreadRingLayer)
        ensureUnreadPulse()
        layoutUnreadRing()

        // Session title shown while the pill is stretched (replaces the dots).
        expandTitleLayer = CATextLayer()
        expandTitleLayer.alignmentMode = .center
        expandTitleLayer.truncationMode = .end
        expandTitleLayer.contentsScale = 2
        expandTitleLayer.foregroundColor = Theme.text.cgColor
        expandTitleLayer.zPosition = 5
        expandTitleLayer.isHidden = true
        capsuleLayer.addSublayer(expandTitleLayer)

        panel.contentView = rootView

        // Grown-mode content views (hidden until showGrown).
        grownStatusLabel = NSTextField(labelWithString: "")
        grownStatusLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        grownStatusLabel.textColor = Theme.accent
        grownStatusLabel.lineBreakMode = .byTruncatingTail
        grownStatusLabel.isHidden = true
        rootView.addSubview(grownStatusLabel)

        grownHintLabel = NSTextField(labelWithString: "")
        grownHintLabel.font = .systemFont(ofSize: 10.5)
        grownHintLabel.textColor = Theme.text2
        grownHintLabel.lineBreakMode = .byTruncatingTail
        grownHintLabel.isHidden = true
        rootView.addSubview(grownHintLabel)

        grownTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: grownWidth - 24, height: 24))
        grownTextView.isEditable = false
        grownTextView.isSelectable = true
        grownTextView.drawsBackground = false
        grownTextView.isRichText = false
        grownTextView.textContainerInset = NSSize(width: 2, height: 2)
        grownTextView.textContainer?.lineFragmentPadding = 0
        grownTextView.textContainer?.widthTracksTextView = true
        grownTextView.isVerticallyResizable = true
        grownTextView.isHorizontallyResizable = false
        grownTextView.autoresizingMask = [.width]
        grownTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        grownScroll = NSScrollView()
        grownScroll.drawsBackground = false
        grownScroll.hasVerticalScroller = true
        grownScroll.scrollerStyle = .overlay
        grownScroll.documentView = grownTextView
        grownScroll.isHidden = true
        rootView.addSubview(grownScroll)

        func makeIcon(_ symbol: String, action: Selector) -> NSButton {
            let button = NSButton(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 8.5, weight: .semibold)) ?? NSImage(),
                target: self, action: action)
            button.isBordered = false
            button.contentTintColor = Theme.text2
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(r: 56, g: 52, b: 48).cgColor
            button.layer?.cornerRadius = 8
            button.isHidden = true
            rootView.addSubview(button)
            return button
        }
        iconSpeaker = makeIcon("speaker.wave.2.fill", action: #selector(grownSpeakTapped))
        iconTrash = makeIcon("trash.fill", action: #selector(grownTrashTapped))
        iconClose = makeIcon("xmark", action: #selector(grownCloseTapped))

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
        ensureUnreadPulse()
        // Display layouts often settle a beat after the notification —
        // recenter again so the pill doesn't strand on stale coordinates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.recenter()
        }
    }

    @objc private func wokeUp() {
        recenter()
        applyState(force: true)
        ensureUnreadPulse()
    }

    private func recenter() {
        // Docked to the reply bubble? Stay there.
        if let dockFrame {
            dock(into: dockFrame)
            return
        }
        // The pill is a stable home surface. State changes (including a
        // session selection) must not move it to the pointer's display.
        guard let display = DisplayTopology.primary else { return }
        let frame = display.frame
        let size = panelSize
        let x = (frame.minX + (frame.width - size.width) / 2).rounded()
        let y = (frame.minY + 5).rounded()
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // ── State inputs ────────────────────────────────────

    func setState(_ newState: AppState, recordingFor capability: CaptureCapability = .dictate) {
        state = newState
        recordingCapability = capability
        if newState == .recording || newState == .handsFree || newState == .processing {
            revertGrownBandToDots()
        }
        if newState == .idle, resumeAutoHideOnIdle {
            resumeAutoHideOnIdle = false
            if mode == .grown {
                expandTimer?.invalidate()
                expandTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                    self?.hideGrown()
                }
            }
        }
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

    func setWatcherActive(_ active: Bool) {
        watcherActive = active
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
        case idle, handsFree, processing, booting, done
        case recording(CaptureCapability)
        case agent(AgentActivity)
        case ttsPlaying, ttsGenerating, ttsPaused
    }

    private func resolveVisual() -> Visual {
        switch state {
        case .recording: return .recording(recordingCapability)
        case .handsFree: return .handsFree
        case .processing: return .processing
        case .loading: return .booting
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

        // The rings are orthogonal to the pill visual — updating them
        // alone must not restart the pill/dot loops. The watcher ring
        // hides under a live session so only one ring reads at a time.
        let rings = (session: sessionActive, watcher: watcherActive)
        if force || appliedRing == nil || appliedRing! != rings {
            appliedRing = rings
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sessionRingLayer.borderWidth = sessionActive ? 1.5 : 0
            sessionRingLayer.opacity = sessionActive ? 1.0 : 0.0
            watcherRingLayer.opacity = (watcherActive && !sessionActive) ? 1.0 : 0.0
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
        case .recording(let capability):
            // Hue says what evidence is being collected; destination is
            // contextual and must never leak back into capture visuals.
            switch capability {
            case .dictate, .continuous:
                paint(bg: NSColor(r: 110, g: 50, b: 45, a: 115),
                      border: NSColor(r: 220, g: 160, b: 140, a: 45),
                      dots: NSColor(r: 255, g: 240, b: 220, a: 180))
            case .snapshot:
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

        case .booting:
            // Backend still starting — cool, quiet, all dots breathing in
            // unison ("warming up"), unlike any working state.
            paint(bg: NSColor(r: 48, g: 52, b: 62, a: 105),
                  border: NSColor(r: 150, g: 170, b: 205, a: 32),
                  dots: NSColor(r: 205, g: 218, b: 240, a: 150))
            addDotBreathe(cycle: 2.4)

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
            addDotEqualizer(cycle: 0.95)

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

    /// All dots fade together, same phase — "warming up", not "working".
    private func addDotBreathe(cycle: Double) {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0.45; a.toValue = 1.0
        a.duration = cycle; a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dotLayers.forEach { $0.add(a, forKey: "breathe") }
    }

    /// Dots stretch vertically out of phase — a small equalizer, reads as
    /// "audio playing" without pulsing the whole pill.
    private func addDotEqualizer(cycle: Double) {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let now = CACurrentMediaTime()
        for (i, dot) in dotLayers.enumerated() {
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [1.0, 1.55, 0.85, 1.3, 1.0]
            a.keyTimes = [0.0, 0.3, 0.55, 0.8, 1.0]
            a.timingFunctions = [ease, ease, ease, ease]
            a.duration = cycle; a.repeatCount = .infinity
            a.beginTime = now - Double(i) * cycle / 3.0
            dot.add(a, forKey: "equalizer")
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
            withTitle: sessionActive ? "End Continuous Capture" : "Start Continuous Capture",
            action: #selector(ctxToggleSession), keyEquivalent: "")
        sessionItem.target = self
        let watcherItem = menu.addItem(
            withTitle: "Watch Workflow",
            action: #selector(ctxToggleWatcher), keyEquivalent: "")
        watcherItem.target = self
        watcherItem.state = watcherActive ? .on : .off
        menu.addItem(withTitle: "Annotate Screen", action: #selector(ctxAnnotate), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Dictation History", action: #selector(ctxHistory), keyEquivalent: "").target = self
        // Kick a Claude session out of the picker by hand (it comes back
        // by itself if it's actually still alive and calls again).
        let removals = onSessionRemovals?() ?? []
        if !removals.isEmpty {
            let removeMenu = NSMenu(title: "Remove Session")
            for (id, label) in removals {
                let item = NSMenuItem(title: label, action: #selector(ctxRemoveSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                removeMenu.addItem(item)
            }
            let removeItem = menu.addItem(withTitle: "Remove Session", action: nil, keyEquivalent: "")
            menu.setSubmenu(removeMenu, for: removeItem)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Voice Flow", action: #selector(ctxQuit), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: point, in: view)
    }
    @objc private func ctxToggleSession() { onToggleSession?() }
    @objc private func ctxToggleWatcher() { onToggleWatcher?() }
    @objc private func ctxAnnotate() { onToggleAnnotate?() }
    @objc private func ctxHistory() { onShowHistory?() }
    @objc private func ctxRemoveSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onRemoveSession?(id) }
    }
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

/// Where a capture went. Stored as data only — the Inbox filter chips are the
/// one place it surfaces; rows never label it (panel redesign, ticket #15).
enum CaptureDestination: String, Codable {
    case pasted      // landed in the frontmost app (classic dictation)
    case kept        // brain dump — recorded into Voice Flow only (ticket #2)
    case assistant   // routed to the in-app assistant
    case session     // routed to a Claude session
}

struct HistoryEntry: Codable {
    var text: String
    var time: String
    /// Full creation date-time for processing cursors. Optional so existing
    /// history continues to decode without rewriting or dropping any fields.
    var timestamp: String?
    /// Stable identity for Continue-append and cross-device sync upserts
    /// (ticket #36). Optional so existing entries keep decoding; assigned
    /// lazily the first time identity is needed.
    var id: String?
    // Optional so pre-redesign dictations.json entries still decode:
    // nil destination = pasted, nil seen = already revisited.
    var destination: CaptureDestination?
    var seen: Bool?
    /// Optional so existing dictations.json and mobile records keep decoding.
    /// Local paths are intentionally not synced to Android.
    var capability: CaptureCapability?
    var attachments: [String]?
    var captureId: String?

    var effectiveDestination: CaptureDestination { destination ?? .pasted }
    /// Only kept items carry unread semantics.
    var isUnrevisited: Bool { effectiveDestination == .kept && seen == false }
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

final class DictationsView: NSView, NSGestureRecognizerDelegate {
    /// The Inbox filters — views over HistoryEntry.destination.
    private enum InboxFilter: Int, CaseIterable {
        case all, kept, pasted, assistant
        var label: String {
            switch self {
            case .all: return "All"; case .kept: return "Kept"
            case .pasted: return "Pasted"; case .assistant: return "Assistant"
            }
        }
        func matches(_ entry: HistoryEntry) -> Bool {
            switch self {
            case .all: return true
            case .kept: return entry.effectiveDestination == .kept
            case .pasted: return entry.effectiveDestination == .pasted
            case .assistant: return entry.effectiveDestination == .assistant
            }
        }
    }

    private var entries: [HistoryEntry] = []
    private var filter: InboxFilter = .all
    private var chipButtons: [NSButton] = []
    private var contentStack: NSView!          // flipped document view
    private var emptyView: NSView!
    private var scrollView: NSScrollView!

    private let renderCap = 60
    private let storeCap = 200
    private static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-flow/dictations.json")

    /// Kept items not yet revisited — surfaced on the Kept chip and usable
    /// for a future tab badge.
    var unrevisitedCount: Int { entries.filter { $0.isUnrevisited }.count }
    var onUnreadChanged: ((Int) -> Void)?
    /// Hover "Continue" tapped on a row — carries the entry's stable id so
    /// the capture pipeline can freeze the append target (ticket #36).
    var onContinueRequested: ((String) -> Void)?

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
        let chipsRow = NSStackView()
        chipsRow.orientation = .horizontal
        chipsRow.spacing = 6
        chipsRow.translatesAutoresizingMaskIntoConstraints = false
        for f in InboxFilter.allCases {
            let chip = NSButton(title: f.label, target: self, action: #selector(chipTapped(_:)))
            chip.tag = f.rawValue
            chip.isBordered = false
            chip.font = .systemFont(ofSize: 10.5, weight: .semibold)
            chip.wantsLayer = true
            chip.layer?.cornerRadius = 9
            chip.layer?.borderWidth = 1
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.heightAnchor.constraint(equalToConstant: 18).isActive = true
            chipButtons.append(chip)
            chipsRow.addArrangedSubview(chip)
        }
        styleChips()

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

        addSubview(chipsRow)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            chipsRow.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            chipsRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scrollView.topAnchor.constraint(equalTo: chipsRow.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    private func styleChips() {
        for chip in chipButtons {
            let isOn = chip.tag == filter.rawValue
            if chip.tag == InboxFilter.kept.rawValue, unrevisitedCount > 0 {
                chip.title = "Kept \(unrevisitedCount)"
            } else if chip.tag == InboxFilter.kept.rawValue {
                chip.title = "Kept"
            }
            chip.contentTintColor = isOn ? Theme.bg : Theme.text2
            chip.layer?.backgroundColor = isOn ? Theme.accent.cgColor : NSColor.clear.cgColor
            chip.layer?.borderColor = isOn ? Theme.accent.cgColor : Theme.borderHover.cgColor
        }
    }

    @objc private func chipTapped(_ sender: NSButton) {
        filter = InboxFilter(rawValue: sender.tag) ?? .all
        styleChips()
        rebuildContent()
    }

    func addEntry(text: String, time: String,
                  timestamp: String? = nil,
                  destination: CaptureDestination = .pasted, seen: Bool? = nil,
                  capability: CaptureCapability? = nil,
                  attachments: [String] = [], captureId: String? = nil,
                  id: String? = nil) {
        entries.insert(HistoryEntry(text: text, time: time,
                                    timestamp: timestamp ?? Self.fullTimestamp(),
                                    id: id ?? UUID().uuidString,
                                    destination: destination, seen: seen,
                                    capability: capability,
                                    attachments: attachments.isEmpty ? nil : attachments,
                                    captureId: captureId), at: 0)
        if entries.count > storeCap { entries = Array(entries.prefix(storeCap)) }
        DictationsView.saveEntries(entries)
        styleChips()
        rebuildContent()
        onUnreadChanged?(unrevisitedCount)
    }

    /// Continue-append (ticket #36): the new transcript joins the existing
    /// entry with a paragraph break; the entry becomes "new" again — fresh
    /// timestamp, unseen, top of the list — so the intake watermark picks it
    /// back up. Falls back to a fresh kept entry if the target is gone.
    func appendToEntry(id: String, text: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else {
            addEntry(text: text, time: Self.clockTime(), destination: .kept,
                     seen: false, capability: .dictate)
            return
        }
        var entry = entries[idx]
        entry.text += "\n\n" + text
        entry.time = Self.clockTime()
        entry.timestamp = Self.fullTimestamp()
        entry.seen = false
        entries.remove(at: idx)
        entries.insert(entry, at: 0)
        DictationsView.saveEntries(entries)
        styleChips()
        rebuildContent()
        onUnreadChanged?(unrevisitedCount)
    }

    /// Sync path (ticket #36): the phone sends whole entries with stable ids.
    /// A known id whose text changed is an update-in-place (continued on the
    /// phone) — refresh text/timestamp, reset unseen, re-sort to top; an
    /// unknown id is a plain add that adopts the phone's id.
    func upsertEntry(id: String?, text: String, time: String, timestamp: String?,
                     destination: CaptureDestination, seen: Bool?) {
        if let id, let idx = entries.firstIndex(where: { $0.id == id }) {
            guard entries[idx].text != text else { return }
            var entry = entries[idx]
            entry.text = text
            entry.time = time
            entry.timestamp = timestamp ?? Self.fullTimestamp()
            entry.seen = false
            entries.remove(at: idx)
            entries.insert(entry, at: 0)
            DictationsView.saveEntries(entries)
            styleChips()
            rebuildContent()
            onUnreadChanged?(unrevisitedCount)
        } else {
            addEntry(text: text, time: time, timestamp: timestamp,
                     destination: destination, seen: seen, id: id)
        }
    }

    private static func fullTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func clockTime() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }

    private func rebuildContent() {
        contentStack.subviews.forEach { $0.removeFromSuperview() }

        // Filtered, newest first, capped. Rows are nothing but the words
        // (panel redesign): destination and time stay data, not chrome.
        let visible = entries.enumerated()
            .filter { filter.matches($0.element) }
            .prefix(renderCap)

        if visible.isEmpty {
            contentStack.addSubview(emptyView)
            NSLayoutConstraint.activate([
                emptyView.topAnchor.constraint(equalTo: contentStack.topAnchor, constant: 60),
                emptyView.centerXAnchor.constraint(equalTo: contentStack.centerXAnchor),
            ])
            return
        }

        var topAnchor = contentStack.topAnchor
        for (index, entry) in visible {
            let card = makeCard(entry: entry, index: index)
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

    private func makeCard(entry: HistoryEntry, index: Int) -> NSView {
        let card = InboxCard()
        card.entryIndex = index
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Theme.card.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.border.cgColor
        let attachments = entry.attachments ?? []
        card.toolTip = attachments.isEmpty ? "Click to copy" : "Click to copy text + image"

        let textLabel = NSTextField(wrappingLabelWithString: entry.text)
        textLabel.font = .systemFont(ofSize: 13)
        // Unrevisited brain dumps read bright; everything else is quiet.
        textLabel.textColor = entry.isUnrevisited ? Theme.text : Theme.text2
        textLabel.maximumNumberOfLines = 0
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        card.textLabel = textLabel

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        if let thumbnail = HistoryAttachmentThumbnail(paths: attachments) {
            row.addArrangedSubview(thumbnail)
        }
        row.addArrangedSubview(textLabel)
        textLabel.translatesAutoresizingMaskIntoConstraints = false

        // Hover-only "Continue" (ticket #36): dictate more into this entry.
        let continueBtn = PaddedInlineButton(title: "Continue", target: self,
                                             action: #selector(continueClicked(_:)))
        continueBtn.bezelStyle = .inline
        continueBtn.font = .systemFont(ofSize: 11)
        continueBtn.tag = index
        continueBtn.toolTip = "Continue this dictation — record and append"
        continueBtn.alphaValue = 0
        continueBtn.setContentHuggingPriority(.required, for: .horizontal)
        continueBtn.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.addArrangedSubview(continueBtn)
        card.hoverAction = continueBtn

        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(cardClicked(_:)))
        click.delegate = self
        card.addGestureRecognizer(click)
        return card
    }

    /// Let a click over the VISIBLE Continue button reach the button itself
    /// (native press + action) instead of being consumed by the card's
    /// copy recognizer. An invisible button never captures the click.
    func gestureRecognizerShouldBegin(_ gesture: NSGestureRecognizer) -> Bool {
        guard let card = gesture.view as? InboxCard,
              let btn = card.hoverAction, btn.alphaValue > 0.5,
              let host = btn.superview else { return true }
        return !btn.frame.contains(gesture.location(in: host))
    }

    /// Click = copy (green flash) and, for an unrevisited brain dump,
    /// mark it revisited.
    @objc private func cardClicked(_ gesture: NSClickGestureRecognizer) {
        guard let card = gesture.view as? InboxCard,
              card.entryIndex >= 0, card.entryIndex < entries.count else { return }
        // A click on the hover Continue button belongs to the button, not
        // the card's copy behavior.
        if let btn = card.hoverAction, let host = btn.superview,
           btn.frame.contains(gesture.location(in: host)) { return }
        let entry = entries[card.entryIndex]

        CaptureClipboard.copy(text: entry.text, attachmentPaths: entry.attachments ?? [])

        card.layer?.backgroundColor = NSColor(r: 120, g: 180, b: 100, a: 15).cgColor
        card.layer?.borderColor = NSColor(r: 120, g: 180, b: 100, a: 30).cgColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            card.layer?.backgroundColor = Theme.card.cgColor
            card.layer?.borderColor = Theme.border.cgColor
        }

        if entry.isUnrevisited {
            entries[card.entryIndex].seen = true
            DictationsView.saveEntries(entries)
            card.textLabel?.textColor = Theme.text2
            styleChips()
            onUnreadChanged?(unrevisitedCount)
        }
    }

    /// Hover "Continue": pin down the entry's stable id (assigning one to a
    /// pre-#36 entry on first use), then hand it to the capture pipeline.
    @objc private func continueClicked(_ sender: NSButton) {
        guard sender.alphaValue > 0.5 else { return }
        let index = sender.tag
        guard index >= 0, index < entries.count else { return }
        if entries[index].id == nil {
            entries[index].id = UUID().uuidString
            DictationsView.saveEntries(entries)
        }
        guard let id = entries[index].id else { return }
        // Toggle feedback: recording-in-progress shows as Stop; the rebuild
        // after the transcript lands resets the row to a fresh Continue.
        if sender.state == .on {
            sender.state = .off
            sender.title = "Continue"
        } else {
            sender.state = .on
            sender.title = "Stop"
        }
        onContinueRequested?(id)
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
//  Messages view — everything agents pushed over MCP
//  Hosted as the ChatPanel's MAIN tab. Persists to
//  ~/.config/voice-flow/messages.json so the history outlives the
//  sessions (and app restarts) that produced it.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

struct AgentMessageEntry: Codable {
    let time: String
    let session: String
    let text: String
    let isAsk: Bool
}

final class MessagesView: NSView {
    private var entries: [AgentMessageEntry] = []
    private var contentStack: NSView!          // flipped document view
    private var emptyView: NSView!
    private var scrollView: NSScrollView!

    private let renderCap = 60
    private let storeCap = 200
    private static let storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voice-flow/messages.json")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        entries = MessagesView.loadEntries()
        setupUI()
        rebuildContent()
    }
    required init?(coder: NSCoder) { fatalError() }
    convenience init() { self.init(frame: .zero) }

    private func setupUI() {
        let secLabel = NSTextField(labelWithString: "FROM YOUR AGENTS")
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

    func addEntry(time: String, session: String, text: String, isAsk: Bool) {
        // A re-sent duplicate (agent retry loops) refreshes the newest
        // entry's time instead of piling up identical rows.
        if let newest = entries.first, newest.session == session,
           newest.text == text, newest.isAsk == isAsk {
            entries.removeFirst()
        }
        entries.insert(AgentMessageEntry(time: time, session: session, text: text, isAsk: isAsk), at: 0)
        if entries.count > storeCap { entries = Array(entries.prefix(storeCap)) }
        MessagesView.saveEntries(entries)
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
        for entry in entries.prefix(renderCap) {
            let card = makeCard(entry)
            card.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addSubview(card)
            NSLayoutConstraint.activate([
                card.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                card.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
                card.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            ])
            topAnchor = card.bottomAnchor
        }

        let bottom = topAnchor.constraint(equalTo: contentStack.bottomAnchor, constant: -12)
        bottom.priority = .defaultLow
        bottom.isActive = true
    }

    private func makeCard(_ entry: AgentMessageEntry) -> NSView {
        let card = HoverCardView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = Theme.card.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.border.cgColor

        let sessionLabel = NSTextField(labelWithString: entry.isAsk ? "\(entry.session) · ask" : entry.session)
        sessionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sessionLabel.textColor = Theme.accent
        sessionLabel.lineBreakMode = .byTruncatingTail

        let textLabel = NSTextField(wrappingLabelWithString: entry.text)
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = Theme.text
        textLabel.maximumNumberOfLines = 0
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let timeLabel = NSTextField(labelWithString: entry.time)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        timeLabel.textColor = Theme.text3

        let copyBtn = NSButton(title: "Copy", target: self, action: #selector(copyClicked(_:)))
        copyBtn.bezelStyle = .inline
        copyBtn.font = .systemFont(ofSize: 11)
        copyBtn.toolTip = entry.text
        copyBtn.setContentHuggingPriority(.required, for: .horizontal)
        copyBtn.setContentCompressionResistancePriority(.required, for: .horizontal)

        card.addSubview(sessionLabel)
        card.addSubview(textLabel)
        card.addSubview(timeLabel)
        card.addSubview(copyBtn)
        sessionLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        copyBtn.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            sessionLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            sessionLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            sessionLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyBtn.leadingAnchor, constant: -10),

            textLabel.topAnchor.constraint(equalTo: sessionLabel.bottomAnchor, constant: 4),
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

        let t = NSTextField(labelWithString: "Nothing from your agents yet")
        t.font = .systemFont(ofSize: 14, weight: .medium)
        t.textColor = Theme.text2
        t.alignment = .center
        v.addArrangedSubview(t)

        let h = NSTextField(labelWithString: "notify · ask · speak messages land here — and stay after their session ends")
        h.font = .systemFont(ofSize: 12)
        h.textColor = Theme.text3
        h.alignment = .center
        v.addArrangedSubview(h)

        return v
    }

    // ── Persistence ────────────────────────────────────

    private static func loadEntries() -> [AgentMessageEntry] {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([AgentMessageEntry].self, from: data) else { return [] }
        return list
    }

    private static func saveEntries(_ entries: [AgentMessageEntry]) {
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

/// Inline-bezel button whose border keeps breathing room around the title
/// (the stock inline bezel hugs the text).
final class PaddedInlineButton: NSButton {
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += 16
        size.height += 6
        return size
    }
}

/// Inbox row: a hover card that knows which HistoryEntry it renders so a
/// click can copy it and clear its unread state in place.
final class InboxCard: HoverCardView {
    var entryIndex: Int = -1
    weak var textLabel: NSTextField?
    /// Revealed on hover, hidden on exit (the Continue affordance, ticket #36).
    weak var hoverAction: NSButton?
    /// Scroll can move rows under a stationary cursor, firing enters without
    /// matching exits — a single app-wide slot guarantees at most one revealed
    /// button. A button mid-recording (state .on) stays visible regardless.
    private static weak var revealedAction: NSButton?

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if let previous = InboxCard.revealedAction, previous !== hoverAction,
           previous.state != .on {
            previous.alphaValue = 0
        }
        InboxCard.revealedAction = hoverAction
        hoverAction?.alphaValue = 1
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let btn = hoverAction, btn.state != .on {
            btn.alphaValue = 0
        }
        if InboxCard.revealedAction === hoverAction {
            InboxCard.revealedAction = nil
        }
    }
}

/// Compact first-image preview; continuous captures keep the narrow card and
/// surface their remaining evidence as a count instead of a filmstrip.
final class HistoryAttachmentThumbnail: NSView {
    init?(paths: [String]) {
        guard let first = paths.first(where: { NSImage(contentsOfFile: $0) != nil }),
              let image = NSImage(contentsOfFile: first) else { return nil }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(r: 18, g: 16, b: 14).cgColor

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 72),
            heightAnchor.constraint(equalToConstant: 50),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if paths.count > 1 {
            let count = NSTextField(labelWithString: "+\(paths.count - 1)")
            count.font = .systemFont(ofSize: 9, weight: .semibold)
            count.textColor = Theme.text
            count.alignment = .center
            count.wantsLayer = true
            count.layer?.backgroundColor = NSColor(r: 20, g: 18, b: 16, a: 210).cgColor
            count.layer?.cornerRadius = 7
            count.translatesAutoresizingMaskIntoConstraints = false
            addSubview(count)
            NSLayoutConstraint.activate([
                count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
                count.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                count.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
                count.heightAnchor.constraint(equalToConstant: 14),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }
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
