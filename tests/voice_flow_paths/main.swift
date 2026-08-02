import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
let production = VoiceFlowPaths(environment: [:], homeDirectory: home)
require(production.configRoot.path == "/Users/example/.config/voice-flow",
        "production root preserves the existing layout")
require(production.file("settings.json").path == "/Users/example/.config/voice-flow/settings.json",
        "files resolve below the production root")

let isolatedRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("voice-flow-path-test-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: isolatedRoot) }

let isolated = VoiceFlowPaths(
    environment: [VoiceFlowPaths.configRootEnvironmentKey: isolatedRoot.path],
    homeDirectory: home)
require(isolated.configRoot == isolatedRoot.standardizedFileURL,
        "absolute QA override is honored")
require(isolated.contains(isolated.file("messages.json")),
        "normal child is contained")
require(!isolated.contains(URL(fileURLWithPath: "/tmp/not-voice-flow/secret")),
        "outside path is rejected")

let relative = VoiceFlowPaths(
    environment: [VoiceFlowPaths.configRootEnvironmentKey: "relative/root"],
    homeDirectory: home)
require(relative.configRoot.path == "/Users/example/.config/voice-flow",
        "relative override cannot redirect storage")

print("voice-flow paths: ok")
