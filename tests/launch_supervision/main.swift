import Foundation
import ServiceManagement

// Work package V10, launch supervision (06 §3.15, §3.18).
//
// The property list is the whole supervision policy: RunAtLoad starts the app at
// login, KeepAlive with SuccessfulExit false restarts a crash or a force-quit and
// lets a menu Quit stay quit. These assertions are the machine-readable half of
// 06 §8 item 13; the kill -9 / Quit observation on a running Mac is
// docs/runtime-proof/voiceflow-mac/V10/validate.sh.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("not ok - \(message)\n".utf8))
    exit(1)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
}

let executable = "/Applications/Voice Flow.app/Contents/MacOS/voice-flow"

// The launch agent's identity and where its property list ships in the bundle.
expect(LaunchAgent.label == "com.voiceflow.agent", "the launchd label is com.voiceflow.agent")
expect(LaunchAgent.plistFileName == "com.voiceflow.agent.plist", "the property list file is named for the label")
expect(LaunchAgent.bundleRelativePath == "Contents/Library/LaunchAgents/com.voiceflow.agent.plist",
       "the property list ships where SMAppService.agent looks for it")

// The supervision policy, key by key.
let plist = LaunchAgent.propertyList(executablePath: executable)
expect(plist["Label"] as? String == LaunchAgent.label, "the plist carries the label")
expect(plist["RunAtLoad"] as? Bool == true, "the agent starts the app at login")
guard let programArguments = plist["ProgramArguments"] as? [String] else {
    fail("ProgramArguments is an array")
}
expect(programArguments == [executable], "the agent starts the app's own executable")
guard let keepAlive = plist["KeepAlive"] as? [String: Any] else {
    fail("KeepAlive is the conditional form, so a successful Quit stays quit")
}
expect(keepAlive["SuccessfulExit"] as? Bool == false,
       "KeepAlive restarts only an unsuccessful exit")
expect(plist["KeepAlive"] as? Bool == nil,
       "KeepAlive is never unconditional; an unconditional KeepAlive would restart a menu Quit")
expect(plist["ProcessType"] as? String == "Interactive", "the app is an interactive launch agent")

// The plist is real property-list data, not a string a plist parser would refuse.
let data = LaunchAgent.propertyListData(executablePath: executable)
let parsedObject = try? PropertyListSerialization.propertyList(from: data, format: nil)
guard let parsed = parsedObject as? [String: Any] else {
    fail("propertyListData emits a plist PropertyListSerialization can read")
}
expect(parsed["Label"] as? String == LaunchAgent.label, "the serialized plist carries the label")

// The state macOS reports becomes one of four states; the window shows which.
expect(LaunchServiceState.from(status: .enabled) == .enabled, "enabled maps to enabled")
expect(LaunchServiceState.from(status: .requiresApproval) == .requiresApproval,
       "requires approval maps to requires approval")
expect(LaunchServiceState.from(status: .notFound) == .notFound, "not found maps to not found")

// To keep exactly one instance, and always the supervised one, an instance
// started any other way asks launchd for the agent and exits -- but it must not
// do that when launchd is the one that started it, or it would never run.
expect(LaunchSupervisor.decision(launchedByLaunchd: true, state: .enabled) == .becomeTheInstance,
       "an instance launchd started becomes the instance, whatever the agent's state")
expect(LaunchSupervisor.decision(launchedByLaunchd: true, state: .notFound) == .becomeTheInstance,
       "a launchd-started instance never hands back to launchd")
expect(LaunchSupervisor.decision(launchedByLaunchd: false, state: .enabled) == .handOffToLaunchd,
       "a second instance handed to an already-registered agent asks launchd and exits")
expect(LaunchSupervisor.decision(launchedByLaunchd: false, state: .requiresApproval) == .becomeTheInstance,
       "an instance started by hand while the agent waits for approval still runs")
expect(LaunchSupervisor.decision(launchedByLaunchd: false, state: .notFound) == .becomeTheInstance,
       "the first instance registers the agent and runs")
expect(LaunchSupervisor.launchedByLaunchdKey == "VOICE_FLOW_LAUNCHED_BY_LAUNCHD",
       "the environment key that tells a launchd-started instance from a hand-started one")

print("launch supervision tests passed")
