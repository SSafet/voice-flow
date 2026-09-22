import AppKit
import ApplicationServices
import Carbon.HIToolbox
import ColorSync
import CoreGraphics
import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Context probe — one observation, one answer
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Everything VoiceFlow captures carries what was in front when it happened.
//  `ContextObservation` is the plain record of one moment; `ContextProbe`
//  fills it from the live system and folds it into the generated `TPContext`,
//  applying `ContextRules` so a private window yields no title and no address.

/// One moment on the user's screen, already stripped of the private parts by
/// `isPrivate`/`activityFields()`/`context(from:…)`.
struct ContextObservation {
    var app: String
    var bundleID: String?
    var windowTitle: String?
    /// AppKit global points, origin bottom-left.
    var windowRect: CGRect?
    var url: String?
    var incognito: Bool
    var secureInput: Bool
    /// AppKit global points.
    var pointer: CGPoint?

    var isPrivate: Bool {
        ContextRules.isPrivate(bundleID: bundleID, appName: app,
                               secureInput: secureInput, incognito: incognito)
    }

    /// The fields the watcher's activity line carries. A private observation
    /// keeps its application name and geometry but loses its title and address.
    func activityFields() -> [String: Any] {
        var fields: [String: Any] = ["app": app]
        if let bundleID, !bundleID.isEmpty { fields["bundle"] = bundleID }
        if isPrivate {
            fields["private"] = true
        } else {
            if let title = ContextRules.cutWindowTitle(windowTitle), !title.isEmpty {
                fields["title"] = title
            }
            if let url = ContextRules.cleanURL(url), !url.isEmpty {
                fields["url"] = url
            }
        }
        return fields
    }
}

enum ContextProbe {

    /// The pure mapping: fills the generated context, converting window and
    /// pointer geometry into the picture's pixels with the origin at the top
    /// left, and dropping title and address when the moment is private.
    static func context(from observation: ContextObservation, display: DisplayContext,
                        displayUUID: String, pictureSize: CGSize?) -> TPContext {
        var windowBox: [Int]?
        var pointer: [Int]?
        if let pictureSize, pictureSize.width > 0, pictureSize.height > 0 {
            let scaleX = pictureSize.width / display.frame.width
            let scaleY = pictureSize.height / display.frame.height
            if let rect = observation.windowRect {
                windowBox = [
                    Int(((rect.minX - display.frame.minX) * scaleX).rounded()),
                    Int(((display.frame.maxY - rect.maxY) * scaleY).rounded()),
                    Int((rect.width * scaleX).rounded()),
                    Int((rect.height * scaleY).rounded()),
                ]
            }
            if let point = observation.pointer {
                pointer = [
                    Int(((point.x - display.frame.minX) * scaleX).rounded()),
                    Int(((display.frame.maxY - point.y) * scaleY).rounded()),
                ]
            }
        }
        let hidden = observation.isPrivate
        return TPContext(
            app: observation.app,
            bundleID: observation.bundleID,
            display: TPContextDisplay(
                heightPt: Double(display.frame.height),
                index: display.captureIndex,
                scale: Double(display.backingScaleFactor),
                uuid: displayUUID,
                widthPt: Double(display.frame.width)),
            pointer: pointer,
            contextPrivate: hidden,
            url: hidden ? nil : ContextRules.cleanURL(observation.url),
            windowBox: windowBox,
            windowTitle: hidden ? nil : ContextRules.cutWindowTitle(observation.windowTitle))
    }

    /// One live read of the screen: frontmost app, its front window, the front
    /// browser tab and the pointer, with secure input measured now.
    static func observe(display: DisplayContext) -> ContextObservation {
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.localizedName ?? "?"
        let window = frontmostWindow(pid: front?.processIdentifier)
        let browser = browser(app: app)
        return ContextObservation(
            app: app,
            bundleID: front?.bundleIdentifier,
            windowTitle: window.title,
            windowRect: windowRect(from: window.bounds),
            url: browser.url,
            incognito: browser.incognito,
            secureInput: IsSecureEventInputEnabled(),
            pointer: NSEvent.mouseLocation)
    }

    static func current(display: DisplayContext, pictureSize: CGSize?) -> TPContext {
        context(from: observe(display: display), display: display,
                displayUUID: displayUUID(for: display), pictureSize: pictureSize)
    }

    /// The stable per-display identifier the generated context expects.
    static func displayUUID(for display: DisplayContext) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id) else {
            return String(display.id)
        }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    // ── live gathering, lifted out of Watcher.swift ────────────────────

    /// Title and bounds of the frontmost app's front window, from one pass of
    /// the window list (the bounds come free with the title). Bounds are in
    /// CoreGraphics global coordinates, origin top-left.
    static func frontmostWindow(pid: pid_t?) -> (title: String?, bounds: [String: Int]?) {
        guard let pid else { return (nil, nil) }
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return (nil, nil) }
        // An app's first layer-0 window is often an untitled helper (Electron
        // shells in particular), so keep looking for a titled one and only fall
        // back to the first geometry we saw.
        var fallback: (title: String?, bounds: [String: Int]?)?
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? Int == Int(pid),
                  window[kCGWindowLayer as String] as? Int == 0 else { continue }
            let name = window[kCGWindowName as String] as? String
            var bounds: [String: Int]?
            if let raw = window[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) {
                bounds = ["x": Int(rect.minX), "y": Int(rect.minY),
                          "w": Int(rect.width), "h": Int(rect.height)]
            }
            if name?.isEmpty == false { return (name, bounds) }
            if fallback == nil, bounds != nil { fallback = (nil, bounds) }
        }
        return fallback ?? (nil, nil)
    }

    /// CoreGraphics window bounds as AppKit global points, origin bottom-left.
    static func windowRect(from bounds: [String: Int]?) -> CGRect? {
        guard let bounds,
              let x = bounds["x"], let y = bounds["y"],
              let w = bounds["w"], let h = bounds["h"] else { return nil }
        let primaryHeight = DisplayTopology.primary?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
        return CGRect(x: CGFloat(x), y: primaryHeight - CGFloat(y + h),
                      width: CGFloat(w), height: CGFloat(h))
    }

    /// What has keyboard focus, as a shape only — the role and how much text
    /// is in it, never the text. Inside a window whose title never changes,
    /// a rising character count is composing and a non-text role with scroll
    /// activity is reading.
    ///
    /// The messaging timeout is set on the focused element only. Setting it on
    /// the system-wide element is documented to apply to the whole process,
    /// which would shorten every other accessibility call the app makes —
    /// including dictation's text-field streaming.
    static func focusedElement() -> (role: String, chars: Int?)? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let value = focused, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return nil }
        var countRef: CFTypeRef?
        var chars: Int?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success {
            chars = countRef as? Int
        }
        return (role, chars)
    }

    /// Front-tab URL when a known browser is frontmost, and whether the front
    /// window is a private one. One AppleScript per browser, referenced only
    /// when that browser is active — AppleScript resolves app dictionaries at
    /// compile time, so a single script naming an uninstalled browser would
    /// fail outright. First use prompts the user to allow Voice Flow to
    /// control the browser (Automation TCC).
    static func browser(app: String) -> (url: String?, incognito: Bool) {
        let script: String
        let readsMode: Bool
        switch app {
        case "Google Chrome", "Brave Browser", "Arc", "Microsoft Edge", "Vivaldi":
            readsMode = true
            script = """
            tell application "\(app)"
            set theURL to URL of active tab of front window
            try
            set theMode to mode of front window
            on error
            set theMode to "normal"
            end try
            return theURL & linefeed & theMode
            end tell
            """
        case "Safari":
            readsMode = false
            script = "tell application \"Safari\" to get URL of front document"
        default:
            return (nil, false)
        }
        guard let output = runOSAScript(script), !output.isEmpty else { return (nil, false) }
        if readsMode {
            let lines = output.split(separator: "\n", maxSplits: 1,
                                     omittingEmptySubsequences: false)
            let url = lines.first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = lines.count > 1 ? lines[1]
                .trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return (url?.isEmpty == false ? url : nil,
                    mode.localizedCaseInsensitiveContains("incognito"))
        }
        let url = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (url.isEmpty ? nil : url, false)
    }

    private static func runOSAScript(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        // SIGTERM is ignorable; escalate so a wedged osascript cannot hold the
        // tick open until the scheduler's stall guard has to step in.
        let killer = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: killer)
        proc.waitUntilExit()
        killer.cancel()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? nil
    }
}
