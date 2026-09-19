import Foundation

// Work package V10, the one native Settings window (06 §3.15, ruling C20).
//
// Subtraction wins on native windows: one window survives and it holds only what
// must work when the web view does not. The section table below is that window's
// whole shape; the panes that moved to the interface's Settings are gone, and
// this test pins both the survivors and their order.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
}

// The one window, in order: macOS permissions; hotkeys; the microphone; the
// runtimes and their programs; This device's safety switches and connection
// facts; and the About line K8 added.
expect(MacSettingsWindowSection.allCases == [.permissions, .hotkeys, .microphone, .runtimes, .thisDevice, .about],
       "the native window holds exactly the surviving sections, in one order")
expect(MacSettingsWindowSection.allCases.map { $0.title }
        == ["Permissions", "Hotkeys", "Microphone", "Runtimes", "This device", "About"],
       "each section has its one title")

// Each section carries a symbol, so the toolbar is complete and no tab is blank.
for section in MacSettingsWindowSection.allCases {
    expect(!section.symbol.isEmpty, "\(section.rawValue) has a toolbar symbol")
}

// The deleted destinations are not sections of this window.
let deletedDestinations = ["assistant", "dictation", "voice", "watcher", "sync", "workspace",
                           "queue", "daily-focus", "sources", "speech"]
for gone in deletedDestinations {
    expect(!MacSettingsWindowSection.allCases.map { $0.rawValue }.contains(gone),
           "\(gone) is not a native Settings section any more")
}

// "This device" is the one section branch 05's native view owns; it is present
// under the name the design uses, so the allowed-client question (answered with
// the window closed) has a home.
expect(MacSettingsWindowSection.thisDevice.title == "This device", "the device section is spelled as the design spells it")

print("native settings window tests passed")
