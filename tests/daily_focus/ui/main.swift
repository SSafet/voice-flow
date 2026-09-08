import Cocoa
import SwiftUI

// Interactive, isolated host for visually checking the shipping editor.
// Compile with VoiceFlowPaths.swift, DailyFocus.swift and DailyFocusEditor.swift.
let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VF_FOCUS_UI_ROOT"] ?? NSTemporaryDirectory() + "vf-focus-ui")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let file = root.appendingPathComponent("FOCUS-NOW.md")
let snapshot = try DailyFocus.read(from: file)
if snapshot.bytes == nil { try DailyFocus.replace("Today: finish the onboarding fixes. Watch for task switching.", expected: snapshot, to: file) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let content = Form {
    Section {
        DailyFocusEditor(fileURL: file)
    } header: { Text("Daily context") }
    footer: { Text("Shared with assistants and subsequent Watcher reviews. Save replaces the previous briefing; it expires at local midnight.") }
}.formStyle(.grouped).preferredColorScheme(.dark)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 330),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Voice Flow · Daily context QA"
window.contentView = NSHostingView(rootView: content)
window.center(); window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
if let path = ProcessInfo.processInfo.environment["VF_FOCUS_UI_SCREENSHOT"] {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        try? capture.run()
    }
}
app.run()
