import AppKit
import Foundation

// ContextProbe and ContextRules (07 §3.3, §3.5).
//
// What was in front when something was captured, and the redaction that keeps
// a password manager's window title and a private browser window's address out
// of every line, every item and every attachment. The rules are pure so they
// can be checked without a screen; the live probe is the thin layer over
// NSWorkspace and the window list that feeds them.

func vflog(_ message: String) {}

private var failures: [String] = []
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do { if try !condition() { failures.append(message) } }
    catch { failures.append("\(message) — the check itself threw \(error)") }
}
private func finish(_ label: String) -> Never {
    if failures.isEmpty {
        print("\(label): ok")
        exit(0)
    }
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    fputs("\(label): \(failures.count) failure(s)\n", stderr)
    exit(1)
}

// Nothing here may touch the owner's real data folder.
guard VoiceFlowPaths.shared.isIsolated else {
    fputs("FAIL: VOICE_FLOW_CONFIG_ROOT is not an isolated directory\n", stderr)
    exit(1)
}

// ── the web address is stored without its query string ────────────────────

expect(ContextRules.cleanURL("https://pantrella.com/admin/cart?token=abc123#row") == "pantrella.com/admin/cart",
       "cleanURL kept the query string or the fragment")
expect(ContextRules.cleanURL("https://user:secret@example.com/a/b") == "example.com/a/b",
       "cleanURL kept credentials")
expect(ContextRules.cleanURL("https://example.com") == "example.com",
       "cleanURL did not accept a bare host")
expect(ContextRules.cleanURL("https://example.com/") == "example.com",
       "cleanURL kept a lone trailing slash")
expect(ContextRules.cleanURL("http://localhost:8792/t/abc") == "localhost:8792/t/abc",
       "cleanURL dropped a port")
expect(ContextRules.cleanURL("file:///Users/safet/secret.txt") == nil,
       "cleanURL accepted a file address")
expect(ContextRules.cleanURL("javascript:alert(1)") == nil,
       "cleanURL accepted a script address")
expect(ContextRules.cleanURL("not a url at all") == nil, "cleanURL accepted text that is not an address")
expect(ContextRules.cleanURL("") == nil, "cleanURL accepted an empty address")
expect(ContextRules.cleanURL(nil) == nil, "cleanURL accepted nothing")

// ── who counts as private ─────────────────────────────────────────────────

let expectedBundles: Set<String> = [
    "com.1password.1password", "com.agilebits.onepassword7",
    "com.bitwarden.desktop", "com.apple.keychainaccess",
    "com.dashlane.Dashlane", "com.lastpass.LastPass",
    "org.keepassxc.keepassxc", "com.apple.SecurityAgent",
]
expect(ContextRules.privateBundleIDs == expectedBundles,
       "the private bundle identifiers are not the eight of InputCoalescer: \(ContextRules.privateBundleIDs)")

expect(ContextRules.isPrivate(bundleID: "com.1password.1password", appName: "1Password",
                              secureInput: false, incognito: false),
       "a password manager in front was not private")
expect(ContextRules.isPrivate(bundleID: "com.apple.Safari", appName: "Safari",
                              secureInput: true, incognito: false),
       "secure input was not private")
expect(ContextRules.isPrivate(bundleID: "com.google.Chrome", appName: "Google Chrome",
                              secureInput: false, incognito: true),
       "a private browser window was not private")
expect(!ContextRules.isPrivate(bundleID: "com.mitchellh.ghostty", appName: "Ghostty",
                               secureInput: false, incognito: false),
       "an ordinary application was called private")
// The existing archive stored a display name and no bundle identifier, so the
// name alone has to be enough for those lines (07 §6).
expect(ContextRules.isPrivate(bundleID: nil, appName: "1Password 7",
                              secureInput: false, incognito: false),
       "a legacy line naming a password manager was not private")
expect(ContextRules.isPrivate(bundleID: "", appName: "keychain access",
                              secureInput: false, incognito: false),
       "the application-name match is case sensitive")
expect(!ContextRules.isPrivate(bundleID: nil, appName: "Ghostty",
                               secureInput: false, incognito: false),
       "a legacy line for an ordinary application was called private")

// ── the window title is cut, never split through a character ──────────────

let long = String(repeating: "a", count: 130)
expect(ContextRules.cutWindowTitle(long)?.count == 120, "a long window title was not cut to 120")
expect(ContextRules.cutWindowTitle("Pantrella · Admin") == "Pantrella · Admin",
       "a short window title was changed")
expect(ContextRules.cutWindowTitle(nil) == nil, "cutWindowTitle invented a title")
// The 120 is counted in UTF-16 units, and the cut never lands inside a
// character: what comes back is always the beginning of what went in.
let emojiTitle = String(repeating: "b", count: 119) + "👨‍👩‍👧" + "tail"
let cutEmoji = ContextRules.cutWindowTitle(emojiTitle) ?? ""
expect(cutEmoji.utf16.count <= 120, "the cut title is longer than 120 UTF-16 units")
expect(emojiTitle.hasPrefix(cutEmoji), "the cut title is not the beginning of the original")
expect(cutEmoji.hasPrefix(String(repeating: "b", count: 119)), "the cut title lost its beginning")

// ── one observation becomes one Context ───────────────────────────────────

let display = DisplayContext(
    id: 7, frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
    visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
    backingScaleFactor: 2, captureIndex: 1)
let picture = CGSize(width: 720, height: 450)

let ordinary = ContextObservation(
    app: "Google Chrome",
    bundleID: "com.google.Chrome",
    windowTitle: "Pantrella · Admin",
    windowRect: NSRect(x: 100, y: 500, width: 400, height: 300),
    url: "https://pantrella.com/admin/cart?token=abc123",
    incognito: false,
    secureInput: false,
    pointer: CGPoint(x: 200, y: 800))

let context = ContextProbe.context(from: ordinary, display: display,
                                   displayUUID: "A1B2-C3", pictureSize: picture)
expect(context.app == "Google Chrome", "the application name was lost")
expect(context.bundleID == "com.google.Chrome", "the bundle identifier was lost")
expect(context.windowTitle == "Pantrella · Admin", "the window title was lost")
expect(context.url == "pantrella.com/admin/cart", "the address was not cleaned into the context")
expect(context.contextPrivate == false, "an ordinary window was marked private")
expect(context.display.uuid == "A1B2-C3", "the display identifier was lost")
expect(context.display.index == 1, "the display index is not the one-based capture index")
expect(context.display.widthPt == 1440 && context.display.heightPt == 900,
       "the display size in points is wrong: \(context.display.widthPt)×\(context.display.heightPt)")
expect(context.display.scale == 2, "the display scale is wrong: \(context.display.scale)")
// Geometry travels in the picture's pixels with the origin at the top left,
// so a mark or a window box drawn from it lands where the picture shows it.
expect(context.windowBox ?? [] == [50, 50, 200, 150],
       "the window box in picture pixels is wrong: \(String(describing: context.windowBox))")
expect(context.pointer ?? [] == [100, 50],
       "the pointer in picture pixels is wrong: \(String(describing: context.pointer))")

let withoutPicture = ContextProbe.context(from: ordinary, display: display,
                                          displayUUID: "A1B2-C3", pictureSize: nil)
expect(withoutPicture.windowBox == nil && withoutPicture.pointer == nil,
       "geometry was invented although there is no picture to measure it in")
expect(withoutPicture.app == "Google Chrome", "the application name needs a picture, which it must not")

// ── a private context carries no title and no address ─────────────────────

let incognito = ContextObservation(
    app: "Google Chrome",
    bundleID: "com.google.Chrome",
    windowTitle: "Bank · Transfers",
    windowRect: NSRect(x: 0, y: 0, width: 200, height: 200),
    url: "https://bank.example.com/transfer",
    incognito: true,
    secureInput: false,
    pointer: nil)
let hidden = ContextProbe.context(from: incognito, display: display,
                                  displayUUID: "A1B2-C3", pictureSize: picture)
expect(hidden.contextPrivate, "a private browser window was not marked private")
expect(hidden.windowTitle == nil, "a private context kept its window title")
expect(hidden.url == nil, "a private context kept its address")
expect(hidden.app == "Google Chrome", "a private context lost the application name, which it keeps")
expect(hidden.windowBox != nil, "a private context lost the window box, which is not private")

let manager = ContextObservation(
    app: "1Password", bundleID: "com.1password.1password", windowTitle: "All Items",
    windowRect: nil, url: nil, incognito: false, secureInput: false, pointer: nil)
let hiddenManager = ContextProbe.context(from: manager, display: display,
                                         displayUUID: "A1B2-C3", pictureSize: picture)
expect(hiddenManager.contextPrivate && hiddenManager.windowTitle == nil,
       "a password manager's window title was kept")

// ── the watcher's own line follows the same rules ─────────────────────────

let ordinaryLine = ordinary.activityFields()
expect(ordinaryLine["app"] as? String == "Google Chrome", "the activity line lost the application")
expect(ordinaryLine["bundle"] as? String == "com.google.Chrome",
       "the activity line does not carry the bundle identifier")
expect(ordinaryLine["title"] as? String == "Pantrella · Admin", "the activity line lost the title")
expect(ordinaryLine["url"] as? String == "pantrella.com/admin/cart",
       "the activity line kept the query string")
expect(ordinaryLine["private"] == nil, "an ordinary line was marked private")

let incognitoLine = incognito.activityFields()
expect(incognitoLine["private"] as? Bool == true, "a private line is not marked private")
expect(incognitoLine["title"] == nil, "a private line kept the window title")
expect(incognitoLine["url"] == nil, "a private line kept the address")
expect(incognitoLine["app"] as? String == "Google Chrome",
       "a private line lost the application name, which it keeps")
expect(incognitoLine["bundle"] as? String == "com.google.Chrome",
       "a private line lost the bundle identifier, which it keeps")

finish("captured context")
