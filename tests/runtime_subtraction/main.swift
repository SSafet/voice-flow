import Foundation

// What this work package replaces is gone, and what replaced it is wired in
// (R12, master plan "Deletes" of V3). These are reads of the repository's own
// source, the way K8's subtraction check works: each one can find something
// today, which is why it can fail.

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        failures += 1
    }
}

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // tests/runtime_subtraction
    .deletingLastPathComponent()   // tests
    .deletingLastPathComponent()   // the repository

func source(_ relative: String) -> String {
    guard let text = try? String(contentsOf: repositoryRoot.appendingPathComponent(relative),
                                 encoding: .utf8) else {
        FileHandle.standardError.write(Data("FAIL: \(relative) is missing\n".utf8))
        failures += 1
        checks += 1
        return ""
    }
    return text
}

func gone(_ fragment: String, from relative: String, _ why: String) {
    expect(!source(relative).contains(fragment), "\(relative) still has \(fragment): \(why)")
}

func present(_ fragment: String, in relative: String, _ why: String) {
    expect(source(relative).contains(fragment), "\(relative) is missing \(fragment): \(why)")
}

// ── The package's own files exist ────────────────────────────────────────

for file in ["swift/Runtimes/RuntimeFolders.swift",
             "swift/Runtimes/RuntimeRuleFile.swift",
             "swift/Runtimes/RuntimeLauncher.swift",
             "swift/Runtimes/RuntimeHealth.swift",
             "swift/Runtimes/RuntimeSkills.swift",
             "swift/Runtimes/CodexLaunch.swift",
             "swift/Runtimes/ClaudeCodeLaunch.swift",
             "swift/Runtimes/OpenCodeLaunch.swift",
             "swift/Runtimes/Normaliser/RuntimeEvent.swift",
             "swift/Runtimes/Normaliser/CodexNormaliser.swift",
             "swift/Runtimes/Normaliser/ClaudeCodeNormaliser.swift",
             "swift/Runtimes/Normaliser/OpenCodeNormaliser.swift",
             "tools/runtime-turn/main.swift",
             "scripts/runtime-turn.sh"] {
    expect(FileManager.default.fileExists(atPath: repositoryRoot.appendingPathComponent(file).path),
           "\(file) exists")
}
expect(FileManager.default.isExecutableFile(
        atPath: repositoryRoot.appendingPathComponent("scripts/runtime-turn.sh").path),
       "the temporary command-line caller can be run")

// ── One rule file for three runtimes ─────────────────────────────────────

gone("AgentSandbox.launchPrefix(", from: "swift/OpenCodeSupervisor.swift",
     "every runtime is confined through RuntimeRuleFile now")
present("RuntimeRuleFile", in: "swift/OpenCodeSupervisor.swift",
        "OpenCode is started under the one rule file")
present("RuntimeRuleFile", in: "swift/Runtimes/CodexLaunch.swift",
        "Codex is started under the one rule file")
present("RuntimeRuleFile", in: "swift/Runtimes/ClaudeCodeLaunch.swift",
        "Claude Code is started under the one rule file")

// ── The turn request carries three folders, not one ──────────────────────

present("folders: RuntimeFolders", in: "swift/AgentRuntime.swift",
        "a turn request carries the working, persona and scratch folders")
gone("let extraWritableRoots", from: "swift/AgentRuntime.swift",
     "writability is the rule file's business, not the caller's")

// ── The codex exec path for thread turns, and the shared process ─────────

gone("CodexExecBackend()", from: "swift/CodexAgentRuntime.swift",
     "a thread turn always runs on the app server, with no exec fallback")
present("runCodex", in: "swift/AssistantContinuity.swift",
        "codex exec stays for the speech-cleanup system agent")
present("account/read", in: "swift/CodexAppServer.swift",
        "sign-in is asked of the app server, not guessed from a file on disk")
present("CodexProcessPool", in: "swift/CodexAgentRuntime.swift",
        "one codex app-server process per thread")
gone("launchedRoots", from: "swift/CodexAppServer.swift",
     "a process belongs to one thread, so its roots never change under it")
gone("appServerBusy", from: "swift/CodexAppServer.swift",
     "the busy-with-other-folders refusal is gone with the shared process")
gone("extraWritableRoots", from: "swift/CodexAppServer.swift",
     "codex is confined from outside and is given no writable roots of its own")
present("externalSandbox", in: "swift/Runtimes/CodexLaunch.swift",
        "codex is told that something outside already confines it")

// ── Tools and skills are no longer projected into a persona folder ───────

gone("func project(into", from: "swift/AgentTools.swift",
     "the tools are written into OpenCode's own settings folder")
gone(".opencode/tools", from: "swift/AgentTools.swift",
     "nothing is generated inside a persona or a project folder")
gone("static func project(", from: "swift/AgentCapabilities.swift",
     "skills are given by path, so nothing is copied into a folder")
gone("promptBlock(", from: "swift/AgentCapabilities.swift",
     "a skill's body is never pasted into the prompt")
gone("includeSkillBodies", from: "swift/AgentPromptComposer.swift",
     "there is no second way to give a skill any more")
present("RuntimeSkills", in: "swift/AgentPromptComposer.swift",
        "the skills layer is one list of name, description and path")
present("OpenCodeLaunch.writeToolFiles", in: "swift/OpenCodeSupervisor.swift",
        "the tools are written once per server start, into the redirected settings folder")

// ── OpenCode's own delegation tool is off ────────────────────────────────

let permissions = source("swift/AgentPermissionPolicy.swift")
expect(permissions.contains("\"task\": \"deny\""),
       "OpenCode's own task tool is denied: delegation is the platform's tool")
expect(!permissions.contains("\"task\": \"allow\""),
       "and there is no second place that allows it")

if failures == 0 {
    print("runtime subtraction: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("not ok - \(failures) of \(checks) checks failed\n".utf8))
exit(1)
