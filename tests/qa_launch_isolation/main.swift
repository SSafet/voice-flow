import Foundation

let manager = FileManager.default
let sandbox = manager.temporaryDirectory.appendingPathComponent("vf-qa-launch-\(UUID().uuidString)")
try manager.createDirectory(at: sandbox, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: sandbox) }
let home = sandbox.appendingPathComponent("home")
let daily = home.appendingPathComponent(".config/voice-flow")
try manager.createDirectory(at: daily, withIntermediateDirectories: true)
let sentinel = daily.appendingPathComponent("history-sentinel")
try Data("keep daily history".utf8).write(to: sentinel)
let before = try Data(contentsOf: sentinel)

func require(_ condition: Bool, _ text: String) {
    if !condition { FileHandle.standardError.write(Data("not ok - \(text)\n".utf8)); exit(1) }
}
func refused(_ environment: [String: String]) -> Bool {
    do { try QALaunchIsolation.validate(environment: environment, homeDirectory: home); return false }
    catch { return true }
}
require(refused([:]), "envless GUI launch is refused")
require(refused(["VOICE_FLOW_CONFIG_ROOT": "relative-test"]), "relative roots are refused")
require(refused(["VOICE_FLOW_CONFIG_ROOT": daily.path]), "daily root is refused")
require(refused(["VOICE_FLOW_CONFIG_ROOT": daily.appendingPathComponent("qa-child").path]), "a child of daily data is refused")
require(refused(["VOICE_FLOW_CONFIG_ROOT": home.path]), "an ancestor of daily data is refused")
let alias = sandbox.appendingPathComponent("daily-alias")
try manager.createSymbolicLink(at: alias, withDestinationURL: daily)
require(refused(["VOICE_FLOW_CONFIG_ROOT": alias.path]), "a symlink to daily data is refused")
require(refused(["VOICE_FLOW_CONFIG_ROOT": alias.appendingPathComponent("new-child").path]), "a nonexistent child through a daily symlink is refused")
let dangling = sandbox.appendingPathComponent("dangling-daily-alias")
try manager.createSymbolicLink(at: dangling, withDestinationURL: daily.appendingPathComponent("missing"))
require(refused(["VOICE_FLOW_CONFIG_ROOT": dangling.path]), "a dangling alias into daily data is refused")
require(refused(["VOICE_FLOW_CONFIG_ROOT": alias.path + "/../voice-flow"]), "parent traversal through a symlink is refused")
let qaRoot = sandbox.appendingPathComponent("isolated-new-root")
for port in ["8792", "8793", "0", "abc"] {
    require(refused(["VOICE_FLOW_CONFIG_ROOT": qaRoot.path, "VOICE_FLOW_QA_PORT": port]), "unsafe control port is refused")
    require(refused(["VOICE_FLOW_CONFIG_ROOT": qaRoot.path, "VOICE_FLOW_QA_SYNC_PORT": port]), "unsafe sync port is refused")
}
require(refused(["VOICE_FLOW_CONFIG_ROOT": qaRoot.path, "VOICE_FLOW_QA_PORT": "18793"]), "colliding default sync port is refused")
try QALaunchIsolation.validate(environment: ["VOICE_FLOW_CONFIG_ROOT": qaRoot.path,
                                           "VOICE_FLOW_QA_PORT": "18793", "VOICE_FLOW_QA_SYNC_PORT": "18794"], homeDirectory: home)
require(!manager.fileExists(atPath: qaRoot.path), "validation creates no configuration root")
require(try Data(contentsOf: sentinel) == before, "validation never alters existing daily bytes")
print("ok - QA launch refuses absent, overlapping, symlinked and unsafe-port isolation before any writes")
