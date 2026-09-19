import Foundation

// V7, task 3 — the main window's testable rules (06 §3.13; 02 §3.10, §3.12).
//
// AppKit draws the window; these are the decisions the window makes before
// AppKit is involved: where the page comes from, which frame it reopens in,
// which display it first opens on, whether VoiceFlow is a Dock app, and the
// five-second blank-window rule. All of them are pure and none of them opens
// a window, so this suite runs headlessly.

// ── 1. the page is the loopback interface, unless the developer setting says otherwise

expectEqual(ShellWindow.loopbackURL.absoluteString, "http://localhost:8792/",
            "the window loads the loopback interface (06 §3.13, ruling C9)")
expectEqual(try ShellWindow.pageURL(developerURL: nil), ShellWindow.loopbackURL,
            "with no developer URL the window loads the loopback interface")
expectEqual(try ShellWindow.pageURL(developerURL: "   "), ShellWindow.loopbackURL,
            "a blank developer URL is no developer URL")
expectEqual(try ShellWindow.pageURL(developerURL: "https://localhost:5173/").absoluteString,
            "https://localhost:5173/",
            "the hidden developer setting points the web view at a development URL (02 §3.12)")

var refusedDeveloperURL = false
do { _ = try ShellWindow.pageURL(developerURL: "not a url") } catch { refusedDeveloperURL = true }
expect(refusedDeveloperURL, "a developer URL that is not a URL is refused by name")

// ── 2. position and size are remembered per arrangement of displays ─────────

let laptopOnly = ShellWindow.autosaveName(displayIdentifiers: ["37D8832A-2D66-02CA-B9F7-8F30A301B230"])
let laptopAndMonitor = ShellWindow.autosaveName(
    displayIdentifiers: ["37D8832A-2D66-02CA-B9F7-8F30A301B230", "9F2C1A44-11AA-4B7E-8C3D-6E5F4A2B9C10"])
expect(laptopOnly != laptopAndMonitor,
       "\"laptop alone\" and \"laptop plus monitor\" save their frames under different names (06 §3.13)")
expectEqual(ShellWindow.autosaveName(displayIdentifiers: ["b", "a"]),
            ShellWindow.autosaveName(displayIdentifiers: ["a", "b"]),
            "the saved-frame name does not depend on the order the displays are listed in")
expect(laptopOnly.contains("37D8832A-2D66-02CA-B9F7-8F30A301B230"),
       "the saved-frame name carries the display identifiers")

// ── 3. the first opening ever goes to the display under the mouse ───────────

let displays = [
    ShellDisplay(id: "builtin", containsPointer: false),
    ShellDisplay(id: "studio-display", containsPointer: true),
]
expectEqual(ShellWindow.displayUnderPointer(displays, fallback: "builtin"), "studio-display",
            "the window first opens on the display under the pointer (06 §3.13)")
expectEqual(ShellWindow.displayUnderPointer(displays.map { ShellDisplay(id: $0.id, containsPointer: false) },
                                            fallback: "builtin"),
            "builtin",
            "with the pointer on no display the window opens on the fallback")

// ── 4. a Dock icon only while the window is open ────────────────────────────

expectEqual(ShellWindow.activationPolicy(windowVisible: true), .regular,
            "VoiceFlow is a regular app while the window is visible (06 §3.13)")
expectEqual(ShellWindow.activationPolicy(windowVisible: false), .accessory,
            "VoiceFlow is an accessory app while the window is closed (06 §3.13)")

// ── 5. a blank window is never the answer ───────────────────────────────────

expectEqual(ShellWindow.blankWindowDeadline, 5,
            "the interface has five seconds to report that it painted (06 §3.13, 02 §3.12)")
let notice = ShellWindow.blankWindowNotice(buildID: "7cbe540d")
expect(!notice.isEmpty, "a window that never painted shows a native message with the reason")
expect(notice.contains("7cbe540d"), "the notice names the build id the interface should have reported")
expect(notice.lowercased().contains("reload") || notice.lowercased().contains("try again"),
       "the notice offers a reload")

print("shell window: the loopback page, per-display frames, the pointer display, the Dock policy and the blank-window rule passed")
