import Foundation

// The watcher's private-context rule (07 §2.6, §3.3, §3.11).
//
// A private context still writes its activity line, without a title or an
// address, but no picture file appears for those seconds — neither a screen
// frame nor a camera frame. The line's redaction is ContextRules' (S1); the
// decision not to save a picture is WatcherPolicy's and is pinned here.

private var failures: [String] = []
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}
private func finish(_ label: String) -> Never {
    if failures.isEmpty { print("\(label): ok"); exit(0) }
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    fputs("\(label): \(failures.count) failure(s)\n", stderr)
    exit(1)
}

// ── a password manager and a private window are the private contexts ───────

let passwordManager = ContextRules.isPrivate(
    bundleID: "com.1password.1password", appName: "1Password",
    secureInput: false, incognito: false)
let incognitoChrome = ContextRules.isPrivate(
    bundleID: "com.google.Chrome", appName: "Google Chrome",
    secureInput: false, incognito: true)
expect(passwordManager, "1Password in front is not a private context")
expect(incognitoChrome, "an incognito Chrome window is not a private context")

// ── in a private context no picture is saved, however the pixels move ──────

expect(!WatcherPolicy.shouldSaveScreen(
    previousChangedBlocks: nil, threshold: 2, denseApp: false,
    secondsSinceLastFrame: nil, denseFloor: 15, privateContext: passwordManager),
    "the first screen frame was saved while a password manager was in front")
expect(!WatcherPolicy.shouldSaveScreen(
    previousChangedBlocks: 99, threshold: 2, denseApp: true,
    secondsSinceLastFrame: 600, denseFloor: 15, privateContext: incognitoChrome),
    "a changed screen was saved while a private window was in front")
expect(!WatcherPolicy.shouldSaveCamera(
    previousDifference: nil, threshold: 0.03, privateContext: incognitoChrome),
    "the first camera frame was saved while a private window was in front")
expect(!WatcherPolicy.shouldSaveCamera(
    previousDifference: 0.9, threshold: 0.03, privateContext: passwordManager),
    "a changed camera frame was saved while a password manager was in front")

// ── the rule is only about privacy: an ordinary context still saves ───────

expect(WatcherPolicy.shouldSaveScreen(
    previousChangedBlocks: nil, threshold: 2, denseApp: false,
    secondsSinceLastFrame: nil, denseFloor: 15),
    "the default (no private context) no longer saves the first screen frame")
expect(WatcherPolicy.shouldSaveCamera(previousDifference: nil, threshold: 0.03),
       "the default (no private context) no longer saves the first camera frame")

finish("private capture")
