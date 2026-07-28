import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Input coalescer — raw events in, readable actions out
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  A screenshot every five seconds shows the *state* of the work but never
//  the move that produced it. This turns the input stream into the missing
//  half: one line per thing the user actually did.
//
//  Coalescing is deterministic local code — keystrokes merge into a typing
//  run, mouse down/up pairs resolve to a click or a drag, scrolls group into
//  a gesture. A reviewing model only ever sees finished sentences; it never
//  sees a raw event, and never has to infer intent from 400 keydowns.
//
//  Emitted actions (one JSON line each, into the desktop source's
//  `actions.jsonl`):
//
//      type    typed text (or just its length — see redaction)
//      key     a named non-printing key, with a repeat count
//      chord   a modifier combination, e.g. ⌘⇧A
//      click   a click that did not travel
//      drag    a press that moved before release
//      scroll  a scroll gesture, with direction and event count
//      app     the frontmost application changed
//
//  Permission: this uses NSEvent global monitors, which ride on the
//  Accessibility grant Voice Flow already holds and already uses for its
//  hotkeys. It is a *passive* monitor — unlike the hotkey tap it can never
//  consume or alter an event.

final class InputCoalescer {

    struct Action {
        let at: Date
        let kind: String
        var fields: [String: Any]
    }

    /// Called on the main thread as each action completes.
    var onAction: ((Action) -> Void)?

    private(set) var isRunning = false
    /// Nil until something has actually gone wrong (permission revoked).
    private(set) var health: String?

    // Bundle identifiers whose keystrokes are never recorded verbatim, no
    // matter what the focused element claims to be.
    private static let neverVerbatim: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.dashlane.Dashlane", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.apple.SecurityAgent",
    ]

    // Terminals are the one place none of the guards can work. A remote
    // `ssh`/`sudo` prompt is drawn by the far end, so nothing asserts secure
    // input, the focused element is just a terminal view, and the password is
    // typed into what looks exactly like a command. Since no signal separates
    // the two, terminal typing is shape-only. It is a small share of the day
    // and shell history already records the commands.
    private static let shapeOnlyApps: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp.Warp-Stable", "io.alacritty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "co.zeit.hyper",
    ]

    private enum Probe { case allow, redact }

    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var flushTimer: Timer?
    private var appObserver: NSObjectProtocol?

    // Pending typing run.
    private var textBuffer = ""
    private var textCount = 0
    private var textRedacted = false
    private var textStart: Date?
    private var lastKeyAt: Date?
    /// Result of the out-of-band focus probe for the current run. Nil means
    /// "not answered yet" and is treated as redact at flush time — the probe
    /// must never fail open.
    private var probeResult: Probe?
    private var runToken = 0
    private let probeQueue = DispatchQueue(label: "voiceflow.coalescer.probe", qos: .utility)

    // Pending named-key run ("pressed Tab x3").
    private var pendingKeyName: String?
    private var pendingKeyCount = 0

    // Pending mouse press.
    private var downAt: Date?
    private var downPoint: NSPoint = .zero

    // Pending scroll gesture.
    private var scrollCount = 0
    private var scrollDelta: CGFloat = 0
    private var scrollStart: Date?
    private var lastScrollAt: Date?

    private static let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)
    private let typingGap: TimeInterval = 2.0
    private let scrollGap: TimeInterval = 1.0

    // ── lifecycle ──────────────────────────────────────────────────────

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            health = "accessibility not granted"
            vflog("coalescer: accessibility not granted — actions unavailable")
            return
        }
        isRunning = true
        health = nil

        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKey(event)
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.handleMouse(event)
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let name = app.localizedName else { return }
            self?.flushAll()
            self?.emit("app", ["app": name])
        }

        // One timer closes runs that ended by silence rather than by a
        // different kind of event.
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.flushExpired()
        }
        vflog("coalescer: started")
    }

    func stop() {
        guard isRunning else { return }
        flushAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        keyMonitor = nil; mouseMonitor = nil; appObserver = nil
        flushTimer?.invalidate(); flushTimer = nil
        isRunning = false
        vflog("coalescer: stopped")
    }

    /// The Accessibility grant can be revoked while we run; a global monitor
    /// keeps returning a live token either way, so the token is not a health
    /// signal — ask the system directly.
    func recheckPermission() {
        guard isRunning else { return }
        if !AXIsProcessTrusted() {
            health = "accessibility revoked"
            stop()
        }
    }

    // ── keyboard ───────────────────────────────────────────────────────

    private func handleKey(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Self.ownPID { return }
        let now = Date()
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // A chord is its own action — flush whatever run it interrupts.
        if mods.contains(.command) || mods.contains(.control) {
            flushText(); flushKeys()
            emit("chord", ["text": Self.chordLabel(mods: mods, event: event), "app": Self.frontApp()])
            return
        }

        if let named = Self.namedKey(event.keyCode) {
            // Backspace edits the run in place rather than ending it — the
            // point of a typing run is what was left standing, not the
            // keystroke count.
            if named == "Delete", textCount > 0 {
                if !textBuffer.isEmpty { textBuffer.removeLast() }
                textCount = max(0, textCount - 1)
                lastKeyAt = now
                return
            }
            flushText()
            if pendingKeyName == named {
                pendingKeyCount += 1
            } else {
                flushKeys()
                pendingKeyName = named
                pendingKeyCount = 1
            }
            lastKeyAt = now
            return
        }

        guard let chars = event.characters, !chars.isEmpty,
              chars.rangeOfCharacter(from: .controlCharacters) == nil else { return }

        flushKeys()
        if textStart == nil { beginTextRun(at: now) }
        // Secure input can be asserted part-way through a run (focus moves
        // into a password field), so re-check it on every keystroke.
        if IsSecureEventInputEnabled() { textRedacted = true }
        if !textRedacted { textBuffer += chars }
        textCount += chars.count
        lastKeyAt = now
    }

    /// Open a typing run. Only the free checks happen here — the accessibility
    /// probe is six synchronous round trips and this is the main thread, so it
    /// runs off-thread and its answer is applied when it lands. Text is
    /// buffered meanwhile and only released at flush if the probe said allow.
    private func beginTextRun(at now: Date) {
        textStart = now
        runToken &+= 1
        let token = runToken
        probeResult = nil

        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        if IsSecureEventInputEnabled()
            || Self.neverVerbatim.contains(bundle)
            || Self.shapeOnlyApps.contains(bundle) {
            textRedacted = true
            probeResult = .redact
            return
        }
        textRedacted = false
        probeQueue.async { [weak self] in
            let result = Self.probeFocus()
            DispatchQueue.main.async {
                guard let self, self.runToken == token else { return }
                self.probeResult = result
                if result == .redact {
                    self.textRedacted = true
                    self.textBuffer = ""
                }
            }
        }
    }

    // ── mouse ──────────────────────────────────────────────────────────

    private func handleMouse(_ event: NSEvent) {
        if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Self.ownPID { return }
        let now = Date()
        switch event.type {
        case .leftMouseDown:
            flushText(); flushKeys(); flushScroll()
            downAt = now
            downPoint = NSEvent.mouseLocation
        case .leftMouseUp:
            guard downAt != nil else { return }
            let up = NSEvent.mouseLocation
            let travel = hypot(up.x - downPoint.x, up.y - downPoint.y)
            var fields = Self.pointFields(downPoint)
            fields["app"] = Self.frontApp()
            if travel < 6 {
                emit("click", fields)
            } else {
                let to = Self.pointFields(up)
                fields["x2"] = to["x"]; fields["y2"] = to["y"]
                emit("drag", fields)
            }
            downAt = nil
        case .rightMouseDown:
            flushText(); flushKeys(); flushScroll()
            var fields = Self.pointFields(NSEvent.mouseLocation)
            fields["app"] = Self.frontApp()
            emit("rclick", fields)
        case .scrollWheel:
            if scrollStart == nil { scrollStart = now }
            scrollCount += 1
            scrollDelta += event.scrollingDeltaY
            lastScrollAt = now
        default:
            break
        }
    }

    // ── flushing ───────────────────────────────────────────────────────

    private func flushExpired() {
        let now = Date()
        if let last = lastKeyAt, now.timeIntervalSince(last) >= typingGap {
            flushText(); flushKeys()
        }
        if let last = lastScrollAt, now.timeIntervalSince(last) >= scrollGap {
            flushScroll()
        }
    }

    private func flushAll() { flushText(); flushKeys(); flushScroll() }

    private func flushText() {
        defer {
            textBuffer = ""; textCount = 0; textStart = nil
            textRedacted = false; lastKeyAt = nil; probeResult = nil
        }
        guard textCount > 0 else { return }
        var fields: [String: Any] = ["chars": textCount, "app": Self.frontApp()]

        // Everything that is not a positive "this is safe" is redacted: an
        // unanswered or failed probe, a password-ish field, secure input, a
        // shape-only app. A lost sentence is recoverable; a logged password is
        // not. A short all-digit run is also dropped — one-time codes and PINs
        // auto-advance between fields, which no per-run probe can see, and a
        // string of digits carries almost no behavioural meaning anyway.
        let digitsOnly = textCount <= 12 && !textBuffer.isEmpty
            && textBuffer.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }
        if textRedacted || probeResult != .allow || digitsOnly {
            fields["redacted"] = true
        } else {
            fields["text"] = textBuffer
        }
        if let start = textStart { fields["ms"] = Int(Date().timeIntervalSince(start) * 1000) }
        emit("type", fields)
    }

    private func flushKeys() {
        defer { pendingKeyName = nil; pendingKeyCount = 0 }
        guard let name = pendingKeyName, pendingKeyCount > 0 else { return }
        var fields: [String: Any] = ["text": name, "app": Self.frontApp()]
        if pendingKeyCount > 1 { fields["n"] = pendingKeyCount }
        emit("key", fields)
    }

    private func flushScroll() {
        defer { scrollCount = 0; scrollDelta = 0; scrollStart = nil; lastScrollAt = nil }
        guard scrollCount > 0 else { return }
        var fields: [String: Any] = [
            "dir": scrollDelta >= 0 ? "up" : "down",
            "n": scrollCount,
            "app": Self.frontApp(),
        ]
        if let start = scrollStart { fields["ms"] = Int(Date().timeIntervalSince(start) * 1000) }
        emit("scroll", fields)
    }

    private func emit(_ kind: String, _ fields: [String: Any]) {
        onAction?(Action(at: Date(), kind: kind, fields: fields))
    }

    // ── helpers ────────────────────────────────────────────────────────

    private static func frontApp() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    }

    /// Position within the display, in per-mille (0–1000 across, 0–1000 down,
    /// top-left origin).
    ///
    /// Deliberately NOT pixels. Frames are stored downscaled to a 1568 px long
    /// edge while the app's own screenshot space is capped at 1440, so any
    /// pixel coordinate would be in a different space than the frame it is
    /// meant to point at — measured ~8% off. A fraction of the display is true
    /// against every frame regardless of how either side is scaled, and reads
    /// naturally to a model: 716 is "72% across".
    private static func pointFields(_ global: NSPoint) -> [String: Any] {
        guard let display = DisplayTopology.displays.first(where: { NSMouseInRect(global, $0.frame, false) })
                ?? DisplayTopology.primary, display.frame.width > 0, display.frame.height > 0 else {
            return [:]
        }
        let x = (global.x - display.frame.minX) / display.frame.width
        let y = (display.frame.maxY - global.y) / display.frame.height
        return [
            "x": Int((x * 1000).rounded()),
            "y": Int((y * 1000).rounded()),
            "display": Int(display.id),
        ]
    }

    /// Ask the focused element whether it is a secret field. Runs off the main
    /// thread; **only ever returns `.allow` on positive evidence that the field
    /// is ordinary.** Every failure — a timeout, a busy app, no focused
    /// element, accessibility disabled — returns `.redact`.
    ///
    /// Note it never touches the system-wide element's messaging timeout:
    /// setting that is documented to change the timeout for the whole process,
    /// which would silently shorten every other accessibility call Voice Flow
    /// makes, including dictation's text-field streaming.
    private static func probeFocus() -> Probe {
        var focused: CFTypeRef?
        let system = AXUIElementCreateSystemWide()
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .redact }
        let element = value as! AXUIElement
        // Scoped to this element only, and generous: this runs at most once per
        // typing run, off the main thread, and a slow answer must not become a
        // silent "not a password".
        AXUIElementSetMessagingTimeout(element, 0.5)

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return .redact }
        if role == "AXSecureTextField" { return .redact }

        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           subrole.localizedCaseInsensitiveContains("secure") || subrole.localizedCaseInsensitiveContains("password") {
            return .redact
        }

        // Web and Electron password inputs usually expose no distinct role —
        // the hint is in the label, placeholder or description.
        for attr in [kAXDescriptionAttribute, kAXPlaceholderValueAttribute, kAXTitleAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               let s = ref as? String,
               s.localizedCaseInsensitiveContains("password") || s.localizedCaseInsensitiveContains("passcode")
                || s.localizedCaseInsensitiveContains("secret") || s.localizedCaseInsensitiveContains("pin") {
                return .redact
            }
        }
        return .allow
    }

    private static func namedKey(_ code: UInt16) -> String? {
        switch Int(code) {
        case kVK_Return, kVK_ANSI_KeypadEnter: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_Escape: return "Escape"
        case kVK_LeftArrow: return "Left"
        case kVK_RightArrow: return "Right"
        case kVK_UpArrow: return "Up"
        case kVK_DownArrow: return "Down"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        default: return nil
        }
    }

    private static func chordLabel(mods: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var label = ""
        if mods.contains(.control) { label += "⌃" }
        if mods.contains(.option) { label += "⌥" }
        if mods.contains(.shift) { label += "⇧" }
        if mods.contains(.command) { label += "⌘" }
        if let named = namedKey(event.keyCode) {
            return label + named
        }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return label + key
    }
}
