import Cocoa

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func saveUIPreview(_ view: NSView, name: String) {
    let directory: URL
    if let artifacts = ProcessInfo.processInfo.environment["VOICE_FLOW_TEST_ARTIFACTS"] {
        directory = URL(fileURLWithPath: artifacts).appendingPathComponent("workspace-ui")
    } else {
        directory = VoiceFlowPaths.shared.directory("qa-editor-visuals")
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    view.appearance = NSAppearance(named: .darkAqua)
    view.wantsLayer = true
    view.layer?.backgroundColor = Theme.bg.cgColor
    view.window?.layoutIfNeeded()
    if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?
            .write(to: directory.appendingPathComponent(name + ".png"))
    }
}

_ = NSApplication.shared
runRowAccessibilityTests()
runComposerTests()
runWorkspaceEditorTests()
print("workspace UI tests passed")
