import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let testRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("voice-flow-path-test-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: testRoot) }
let home = testRoot.appendingPathComponent("home", isDirectory: true)
let productionRoot = home.appendingPathComponent(".config/voice-flow", isDirectory: true)
let production = VoiceFlowPaths(environment: [:], homeDirectory: home)
require(production.configRoot == productionRoot.standardizedFileURL,
        "production root preserves the existing layout")
require(production.file("settings.json") == productionRoot.appendingPathComponent("settings.json"),
        "files resolve below the production root")

let isolatedRoot = testRoot.appendingPathComponent("isolated", isDirectory: true)

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
require(relative.configRoot == productionRoot.standardizedFileURL,
        "relative override cannot redirect storage")

require(!production.isIsolated, "an instance without an override is not isolated")
require(isolated.isIsolated, "an accepted override is isolated independently of the process environment")
require(!relative.isIsolated, "a rejected relative override cannot authorize QA against production storage")
let empty = VoiceFlowPaths(environment: [VoiceFlowPaths.configRootEnvironmentKey: ""], homeDirectory: home)
require(!empty.isIsolated, "an empty override cannot authorize QA")
let sameRoot = VoiceFlowPaths(environment: [VoiceFlowPaths.configRootEnvironmentKey: productionRoot.path], homeDirectory: home)
require(!sameRoot.isIsolated, "an explicit production root is not isolated")
let alias = testRoot.appendingPathComponent("production-alias", isDirectory: true)
try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: productionRoot)
let aliased = VoiceFlowPaths(environment: [VoiceFlowPaths.configRootEnvironmentKey: alias.path], homeDirectory: home)
require(!aliased.isIsolated, "a symlink to the production root is not isolated")

print("voice-flow paths: ok")
