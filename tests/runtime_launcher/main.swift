import Foundation

// The runtime launcher (06 §3.6): the three folders of a turn, the refusals
// that happen before a process is started, what each runtime is actually
// started with, one Codex process per thread, and the status this Mac reports
// as its home's runtimes.
//
// Nothing here talks to a vendor. The process pool is driven with /bin/cat,
// which is a real child process with a real pid, so the lifetime rules are
// exercised rather than described.

func vflog(_ message: String) {}

var failures = 0
var checks = 0
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        failures += 1
    }
}

func expectThrows(_ label: String,
                  code: TPErrorCode,
                  contains fragment: String,
                  _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        FileHandle.standardError.write(Data("FAIL: \(label): nothing was thrown\n".utf8))
        failures += 1
    } catch let error as RuntimeLaunchError {
        if error.code != code {
            FileHandle.standardError.write(Data("FAIL: \(label): code \(error.code.rawValue)\n".utf8))
            failures += 1
        } else if !error.message.contains(fragment) {
            FileHandle.standardError.write(
                Data("FAIL: \(label): message \(error.message.debugDescription) does not name \(fragment)\n".utf8))
            failures += 1
        }
    } catch {
        FileHandle.standardError.write(Data("FAIL: \(label): \(error)\n".utf8))
        failures += 1
    }
}

let manager = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vf-runtime-launcher-\(UUID().uuidString)", isDirectory: true)
let configRoot = scratch.appendingPathComponent("config", isDirectory: true)
let project = scratch.appendingPathComponent("project", isDirectory: true)
try manager.createDirectory(at: project, withIntermediateDirectories: true)
try manager.createDirectory(at: configRoot, withIntermediateDirectories: true)
defer { try? manager.removeItem(at: scratch) }

let personaDirectory = configRoot.appendingPathComponent("personas/flora", isDirectory: true)
let folders = RuntimeFolders(
    workingDirectory: project,
    personaDirectory: personaDirectory,
    scratchDirectory: RuntimeFolders.scratchDirectory(threadID: "th-1", configRoot: configRoot))
let toolEndpoint = URL(string: "http://127.0.0.1:52344/tool")!
let workingSandbox = SandboxHealth(working: true, detail: nil)
let brokenSandbox = SandboxHealth(working: false, detail: "sandbox-exec exited with 65")

func rules(_ runtime: AgentRuntimeKind,
           profile: AgentTrustProfile = .workspace) -> RuntimeRuleFile.Inputs {
    RuntimeRuleFile.Inputs(
        runtime: runtime, trustProfile: profile, folders: folders,
        projectRoots: [project], grantedRoots: [],
        runtimeHome: configRoot.appendingPathComponent("runtime/\(runtime.rawValue)", isDirectory: true),
        dial: AgentCapabilityDial(), configRoot: configRoot)
}

// ── The three folders ────────────────────────────────────────────────────

expect(RuntimeFolders.scratchDirectory(threadID: "th-1", configRoot: configRoot).path
        == configRoot.appendingPathComponent("thread-scratch/th-1").path,
       "the scratch folder is thread-scratch/<thread> inside the configuration root")
expect(manager.fileExists(atPath: folders.scratchDirectory.path),
       "asking for the scratch folder creates it")
expect(folders.workingDirectory == project, "the working folder is the thread's workspace root")

// ── Refusals, before anything is started ─────────────────────────────────

var noCommands = AgentCapabilityDial()
noCommands.runCommands = false
var noNetwork = AgentCapabilityDial()
noNetwork.reachNetwork = false

for runtime in [AgentRuntimeKind.codex, .claude] {
    expectThrows("\(runtime.rawValue) with run commands off",
                 code: .disabledOnDevice, contains: "run commands") {
        try RuntimeLauncher.preflight(runtime: runtime, dial: noCommands,
                                      installedVersion: "0.153.2", signedIn: true,
                                      sandbox: workingSandbox, environment: [:])
    }
    expectThrows("\(runtime.rawValue) with reach network off",
                 code: .disabledOnDevice, contains: "reach network") {
        try RuntimeLauncher.preflight(runtime: runtime, dial: noNetwork,
                                      installedVersion: "0.153.2", signedIn: true,
                                      sandbox: workingSandbox, environment: [:])
    }
}
// OpenCode's two switches are kernel rules, not a refusal: it still starts.
do {
    try RuntimeLauncher.preflight(runtime: .opencode, dial: noCommands,
                                  installedVersion: "1.17.11", signedIn: true,
                                  sandbox: workingSandbox, environment: [:])
    checks += 1
} catch {
    expect(false, "opencode with run commands off still starts: \(error)")
}

expectThrows("codex outside the checked range",
             code: .runtimeUnavailable, contains: "0.153.0") {
    try RuntimeLauncher.preflight(runtime: .codex, dial: AgentCapabilityDial(),
                                  installedVersion: "0.140.0", signedIn: true,
                                  sandbox: workingSandbox, environment: [:])
}
expectThrows("codex that is not installed",
             code: .runtimeUnavailable, contains: "Codex") {
    try RuntimeLauncher.preflight(runtime: .codex, dial: AgentCapabilityDial(),
                                  installedVersion: nil, signedIn: true,
                                  sandbox: workingSandbox, environment: [:])
}
expectThrows("a runtime that is not signed in",
             code: .runtimeUnavailable, contains: "sign") {
    try RuntimeLauncher.preflight(runtime: .codex, dial: AgentCapabilityDial(),
                                  installedVersion: "0.153.2", signedIn: false,
                                  sandbox: workingSandbox, environment: [:])
}
// A failed sandbox is checked first: a runtime never starts unconfined, and
// the reason the person is shown is the real one.
expectThrows("every runtime with a failed sandbox",
             code: .runtimeUnavailable, contains: "sandbox") {
    try RuntimeLauncher.preflight(runtime: .codex, dial: noCommands,
                                  installedVersion: nil, signedIn: false,
                                  sandbox: brokenSandbox, environment: [:])
}
do {
    try RuntimeLauncher.preflight(runtime: .codex, dial: AgentCapabilityDial(),
                                  installedVersion: "0.153.2", signedIn: true,
                                  sandbox: workingSandbox, environment: [:])
    checks += 1
} catch {
    expect(false, "a supported Codex with everything on passes preflight: \(error)")
}

// The range the version check uses can be moved for one launch, which is how
// the refusal is observed on a running system (06 §8 item 8).
let moved = RuntimeVersionRange.codex(environment: [
    "VOICE_FLOW_CODEX_VERSION_MIN": "99.0.0",
    "VOICE_FLOW_CODEX_VERSION_MAX": "99.1.0",
])
expect(moved.minimumInclusive == "99.0.0" && moved.maximumExclusive == "99.1.0",
       "the supported Codex range is overridable for one launch")
expect(!moved.contains("0.153.2"), "the installed Codex is outside the moved range")
expect(RuntimeVersionRange.codexDefault.contains("0.153.2"),
       "the installed Codex is inside the default range")
expect(!RuntimeVersionRange.codexDefault.contains("0.9.0"),
       "the range compares numbers, not text: 0.9.0 is below 0.153.0")
expect(!RuntimeVersionRange.codexDefault.contains("0.154.0"),
       "the upper end of the range is excluded")
expect(RuntimeVersionProbe.parse("codex-cli 0.153.2") == "0.153.2",
       "the Codex version is read out of its own line")
expect(RuntimeVersionProbe.parse("2.1.261 (Claude Code)") == "2.1.261",
       "the Claude Code version is read out of its own line")
expect(RuntimeVersionProbe.parse("not a version") == nil,
       "a line with no version reads as no version")

// ── What Codex is started with ───────────────────────────────────────────

let codexPlan = try CodexLaunch.plan(binaryPath: "/opt/homebrew/bin/codex", rules: rules(.codex),
                                     threadID: "th-1", toolEndpoint: toolEndpoint, token: "tok-1")
expect(codexPlan.executableURL.path == "/usr/bin/sandbox-exec",
       "codex is started by sandbox-exec, so the kernel rule applies before its first instruction")
expect(codexPlan.arguments.first == "-f", "the profile is applied with -f")
expect(codexPlan.arguments.contains("/opt/homebrew/bin/codex"),
       "the codex binary is an argument of sandbox-exec")
expect(codexPlan.arguments.contains("app-server"), "codex is started as an app server")
expect(codexPlan.currentDirectory == project, "codex starts in the thread's working folder")
let codexArguments = codexPlan.arguments.joined(separator: " ")
expect(codexArguments.contains("mcp_servers.voiceflow.url=\(toolEndpoint.absoluteString)"),
       "exactly one tool server is configured, and it is VoiceFlow's")
expect(codexArguments.contains("mcp_servers.voiceflow.bearer_token_env_var=\(CodexLaunch.tokenEnvironmentKey)"),
       "the token is passed by environment variable name, never on the command line")
expect(codexArguments.contains("mcp_servers.voiceflow.required=true"),
       "a turn fails rather than quietly running without VoiceFlow's tools")
expect(codexArguments.contains("mcp_servers.voiceflow.tool_timeout_sec=\(CodexLaunch.toolTimeoutSeconds)"),
       "a tool call may wait for a person")
expect(CodexLaunch.toolTimeoutSeconds == 14_400, "the tool time limit is four hours")
expect(!codexArguments.contains("sandbox_mode"),
       "codex no longer applies its own sandbox: VoiceFlow's rule file is the boundary")
expect(!codexArguments.contains("writable_roots"),
       "codex is not given writable roots of its own")
expect(codexPlan.environment[CodexLaunch.tokenEnvironmentKey] == "tok-1",
       "the tool token reaches codex through its environment")

let threadParams = CodexLaunch.threadParams(cwd: project.path, resumeThread: nil, instructions: "be brief")
expect(threadParams["cwd"] as? String == project.path, "the thread is created in the working folder")
expect(threadParams["approvalPolicy"] as? String == "never", "codex never asks for approval itself")
let turnParams = CodexLaunch.turnParams(threadId: "codex-thread", prompt: "hello", imagePaths: [],
                                        cwd: project.path, model: nil, reasoningEffort: nil)
expect(turnParams["cwd"] as? String == project.path, "every turn sends its own working folder")
let sandboxPolicy = turnParams["sandboxPolicy"] as? [String: Any] ?? [:]
expect(sandboxPolicy["type"] as? String == "externalSandbox",
       "every turn tells codex that something outside already confines it")
expect(sandboxPolicy["networkAccess"] as? String == "enabled",
       "codex may reach its vendor through the outer sandbox")

// ── What Claude Code is started with ─────────────────────────────────────

let claudeFolderPlan = try ClaudeCodeLaunch.plan(
    binaryPath: "/usr/local/bin/claude", rules: rules(.claude), folders: folders,
    isFolderProject: true, trustProfile: .workspace, resumeSessionID: nil,
    newSessionID: "session-1", model: nil, reasoningEffort: nil,
    toolEndpoint: toolEndpoint, token: "tok-2", instructions: "be brief")
let claudeArguments = claudeFolderPlan.arguments
expect(claudeFolderPlan.executableURL.path == "/usr/bin/sandbox-exec",
       "claude code is started by sandbox-exec")
func flagValue(_ flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
expect(flagValue("--setting-sources", in: claudeArguments) == "user,project,local",
       "a folder project applies the repository's own instructions, skills and settings")
expect(flagValue("--permission-mode", in: claudeArguments) == "bypassPermissions",
       "workspace bypasses claude code's own confirmations: the kernel rule file is the boundary")
expect(claudeArguments.contains("--strict-mcp-config"),
       "no tool server but VoiceFlow's is loaded")
expect(flagValue("--mcp-config", in: claudeArguments) != nil,
       "VoiceFlow's tool endpoint is named in one configuration")
expect(claudeArguments.contains("--add-dir"),
       "the persona and scratch folders are visible to the turn")
expect(claudeArguments.contains(personaDirectory.path) && claudeArguments.contains(folders.scratchDirectory.path),
       "the persona folder and the thread's scratch folder are the added folders")
expect(claudeFolderPlan.environment["MCP_TOOL_TIMEOUT"] == String(ClaudeCodeLaunch.toolTimeoutMilliseconds),
       "a tool call may wait for a person")
expect(ClaudeCodeLaunch.toolTimeoutMilliseconds == 14_400_000,
       "claude code's tool time limit is four hours, counted in milliseconds")
expect(ClaudeCodeLaunch.permissionMode(for: .observe) == "plan",
       "observe plans instead of acting")
expect(ClaudeCodeLaunch.permissionMode(for: .unattended) == "bypassPermissions",
       "an unattended turn cannot answer a confirmation, so it does not raise one")
expect(ClaudeCodeLaunch.settingSources(isFolderProject: false) == "user",
       "a General-project thread applies only the person's own settings")
let mcpConfig = ClaudeCodeLaunch.mcpConfig(endpoint: toolEndpoint, token: "tok-2")
let servers = mcpConfig["mcpServers"] as? [String: Any] ?? [:]
expect(servers.count == 1, "exactly one tool server is configured")
expect(servers["voiceflow"] != nil, "and it is VoiceFlow's")

// ── OpenCode: tools in the redirected settings folder, never in the project ──

let openCodeHome = configRoot.appendingPathComponent("runtime/opencode/config", isDirectory: true)
let written = try OpenCodeLaunch.writeToolFiles(endpoint: toolEndpoint, token: "tok-3",
                                                configHome: openCodeHome)
let toolsDirectory = OpenCodeLaunch.toolsDirectory(configHome: openCodeHome)
expect(toolsDirectory.path == openCodeHome.appendingPathComponent("opencode/tools").path,
       "the tools are written where OpenCode scans its own settings folder")
expect(!written.isEmpty, "at least one tool file is written")
for name in written {
    expect(manager.fileExists(atPath: toolsDirectory.appendingPathComponent(name).path),
           "\(name) is on disk")
}
let toolSource = try String(contentsOf: toolsDirectory.appendingPathComponent(written[0]), encoding: .utf8)
expect(toolSource.contains("tok-3"), "the generated tool carries this server's token")
expect(!manager.fileExists(atPath: project.appendingPathComponent(".opencode").path),
       "nothing is written into the project folder, so a token never lands in a repository")
expect(!manager.fileExists(atPath: personaDirectory.appendingPathComponent(".opencode").path),
       "nothing is written into the persona folder either")
// Writing again replaces the folder rather than growing it.
let again = try OpenCodeLaunch.writeToolFiles(endpoint: toolEndpoint, token: "tok-4",
                                              configHome: openCodeHome)
expect(again == written, "a second start writes the same set of tools")
let contents = try manager.contentsOfDirectory(atPath: toolsDirectory.path)
expect(contents.count == written.count, "the folder holds exactly the tools of this start")
let refreshed = try String(contentsOf: toolsDirectory.appendingPathComponent(written[0]), encoding: .utf8)
expect(refreshed.contains("tok-4") && !refreshed.contains("tok-3"),
       "the new server's token replaced the old one")

// ── Skills are given by path, never pasted ───────────────────────────────

let skill = AgentSkill(name: "organize-desktop", description: "Tidy the desktop into folders",
                       sourceURL: personaDirectory.appendingPathComponent("skills/organize-desktop/SKILL.md"),
                       contents: "---\nname: organize-desktop\n---\nSTEP ONE SECRET BODY\n",
                       digest: "abc")
let promptList = RuntimeSkills.promptList(skills: [skill])
expect(promptList.contains("organize-desktop"), "the skill's name is in the prompt")
expect(promptList.contains("Tidy the desktop into folders"), "its description is in the prompt")
expect(promptList.contains(skill.sourceURL.path), "its path is in the prompt")
expect(!promptList.contains("STEP ONE SECRET BODY"), "its body is not pasted into the prompt")
expect(RuntimeSkills.promptList(skills: []).isEmpty, "no skills means no skills layer at all")

// ── One Codex process per thread ─────────────────────────────────────────

var clock = Date(timeIntervalSince1970: 1_000_000)
let pool = CodexProcessPool(idleTimeout: 600, now: { clock })
// /bin/cat with a pipe on its input is a real child that stays alive until it
// is stopped, which is all the pool's rules need.
func catPlan() -> RuntimeProcessPlan {
    RuntimeProcessPlan(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                       environment: [:], currentDirectory: project,
                       profilePath: "", binaryPath: "/bin/cat")
}
let first = try pool.process(forThread: "th-1", plan: catPlan())
let same = try pool.process(forThread: "th-1", plan: catPlan())
expect(first === same, "a second turn of the same thread reuses that thread's process")
let other = try pool.process(forThread: "th-2", plan: catPlan())
expect(other !== first, "another thread gets its own process")
expect(first.isRunning && other.isRunning, "both processes are running")
expect(Set(pool.liveThreadIDs) == ["th-1", "th-2"], "the pool knows both threads")

pool.markBusy(threadID: "th-1")
pool.markIdle(threadID: "th-2")
clock = clock.addingTimeInterval(601)
pool.sweepIdle()
expect(first.isRunning, "a thread with a turn running is never swept")
expect(!other.isRunning, "a thread idle for longer than the limit is stopped")
expect(pool.liveThreadIDs == ["th-1"], "the stopped thread is gone from the pool")

let replacement = try pool.process(forThread: "th-2", plan: catPlan())
expect(replacement !== other, "the next turn of a stopped thread starts a new process")
pool.markIdle(threadID: "th-1")
clock = clock.addingTimeInterval(599)
pool.sweepIdle()
expect(first.isRunning, "an idle thread inside the limit is kept")

pool.stopAll()
expect(!first.isRunning && !replacement.isRunning, "quitting stops every process")
expect(pool.liveThreadIDs.isEmpty, "the pool is empty")

// ── Version reading, cached by the binary's modification time ────────────

let fakeBinary = scratch.appendingPathComponent("fake-codex")
let counter = scratch.appendingPathComponent("runs.txt")
func writeFakeBinary(version: String) throws {
    try Data("""
    #!/bin/sh
    echo run >> \(counter.path)
    echo "codex-cli \(version)"
    """.utf8).write(to: fakeBinary)
    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
}
try writeFakeBinary(version: "0.153.2")
let cache = RuntimeVersionCache()
expect(cache.version(ofBinaryAt: fakeBinary.path) == "0.153.2", "the version is read from the binary")
expect(cache.version(ofBinaryAt: fakeBinary.path) == "0.153.2", "and again")
func runCount() -> Int {
    ((try? String(contentsOf: counter, encoding: .utf8)) ?? "")
        .split(separator: "\n").count
}
expect(runCount() == 1, "the second read came from the cache")
try writeFakeBinary(version: "0.153.9")
try manager.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                          ofItemAtPath: fakeBinary.path)
expect(cache.version(ofBinaryAt: fakeBinary.path) == "0.153.9",
       "a changed binary is read again")
expect(cache.version(ofBinaryAt: scratch.appendingPathComponent("absent").path) == nil,
       "a binary that is not there has no version")

// ── The status this Mac reports as its home's runtimes ───────────────────

let installations = [
    RuntimeInstallation(kind: .codex, binaryPath: "/opt/homebrew/bin/codex", version: "0.153.2", signedIn: true),
    RuntimeInstallation(kind: .claude, binaryPath: "/usr/local/bin/claude", version: "2.1.261", signedIn: true),
    RuntimeInstallation(kind: .opencode, binaryPath: nil, version: nil, signedIn: false),
]
let report = RuntimeHealth.report(installations, sandbox: workingSandbox)
expect(report.runtimes.count == 3, "all three runtimes are reported")
let byKind = Dictionary(uniqueKeysWithValues: report.runtimes.map { ($0.kind, $0) })
expect(byKind[.codex]?.available == true, "a supported, signed-in Codex is available")
expect(byKind[.codex]?.version == "0.153.2", "with the version that was measured")
expect(byKind[.codex]?.detail == nil, "and nothing to explain")
expect(byKind[.opencode]?.available == false, "a runtime that is not installed is unavailable")
expect(byKind[.opencode]?.detail?.isEmpty == false, "and says why")
expect(report.sandbox.line == "sandbox: working", "the status carries the sandbox line")

let outOfRange = RuntimeHealth.report([
    RuntimeInstallation(kind: .codex, binaryPath: "/opt/homebrew/bin/codex", version: "0.140.0", signedIn: true),
], sandbox: workingSandbox)
expect(outOfRange.runtimes.first?.available == false, "a Codex outside the range is unavailable")
expect(outOfRange.runtimes.first?.detail?.contains("0.153.0") == true,
       "and the detail names the version that is required")

let broken = RuntimeHealth.report(installations, sandbox: brokenSandbox)
expect(broken.runtimes.allSatisfy { $0.available == false },
       "with a failed sandbox no runtime is available: nothing runs unconfined")
expect(broken.runtimes.allSatisfy { $0.detail?.contains("sandbox") == true },
       "and every one of them says the sandbox is the reason")
expect(broken.sandbox.line.hasPrefix("sandbox: failed"), "the sandbox line says so too")
expect(broken.sandbox.line.contains("65"), "and carries the system's own error")

if failures == 0 {
    print("runtime launcher: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("not ok - \(failures) of \(checks) checks failed\n".utf8))
exit(1)
