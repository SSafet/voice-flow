import Foundation

// One kernel rule file for three runtimes (06 §3.6).
//
// Two halves. The first reads the profile the shipping code renders for each
// runtime and pins what must be in it and in what order — SBPL resolves to the
// LAST matching rule, so a protected path written before its allow line would
// be silently ineffective. The second half runs real escape attempts through
// the real /usr/bin/sandbox-exec under the real profile, because a rendered
// string proves nothing about what the kernel does.
//
// Core.swift is out of this compile, so stub its logger the way the other
// isolated harness suites do.
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

let manager = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("vf-runtime-rules-\(UUID().uuidString)", isDirectory: true)
let configRoot = scratch.appendingPathComponent("config", isDirectory: true)
let project = scratch.appendingPathComponent("project", isDirectory: true)
let grantedFolder = scratch.appendingPathComponent("granted", isDirectory: true)
// "Outside" must be outside every writable root, and TMPDIR is writable, so it
// cannot live beside the scratch tree or the drill would pass for the wrong
// reason.
let outside = manager.homeDirectoryForCurrentUser
    .appendingPathComponent(".vf-runtime-rules-outside-\(UUID().uuidString)", isDirectory: true)
for directory in [configRoot, project, grantedFolder, outside,
                  outside.appendingPathComponent(".ssh", isDirectory: true)] {
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
}
defer {
    try? manager.removeItem(at: scratch)
    try? manager.removeItem(at: outside)
}
try Data("secret\n".utf8).write(to: outside.appendingPathComponent(".ssh/config"))
try Data("public\n".utf8).write(to: outside.appendingPathComponent("plain.txt"))
try Data("in the project\n".utf8).write(to: project.appendingPathComponent("existing.txt"))

let folders = RuntimeFolders(
    workingDirectory: project,
    personaDirectory: configRoot.appendingPathComponent("personas/flora", isDirectory: true),
    scratchDirectory: RuntimeFolders.scratchDirectory(threadID: "thread-a", configRoot: configRoot))
let home = manager.homeDirectoryForCurrentUser.path

func inputs(_ runtime: AgentRuntimeKind,
            profile: AgentTrustProfile = .workspace,
            granted: [String] = [],
            dial: AgentCapabilityDial = AgentCapabilityDial()) -> RuntimeRuleFile.Inputs {
    RuntimeRuleFile.Inputs(
        runtime: runtime,
        trustProfile: profile,
        folders: folders,
        projectRoots: [project],
        grantedRoots: granted.isEmpty ? [grantedFolder.path] : granted,
        runtimeHome: configRoot.appendingPathComponent("runtime/\(runtime.rawValue)", isDirectory: true),
        dial: dial,
        configRoot: configRoot)
}

func profileText(_ value: RuntimeRuleFile.Inputs) -> String {
    RuntimeRuleFile.policy(value).profileText()
}

// ── The shape of the three profiles ──────────────────────────────────────

let openCodeText = profileText(inputs(.opencode))
let codexText = profileText(inputs(.codex))
let claudeText = profileText(inputs(.claude))

for (name, text) in [("opencode", openCodeText), ("codex", codexText), ("claude", claudeText)] {
    expect(text.hasPrefix("(version 1)\n(allow default)"),
           "\(name): the profile starts with (version 1) and (allow default)")
    for writable in [project.path, folders.scratchDirectory.path, grantedFolder.path] {
        expect(text.contains("(subpath \"\(writable)\")"),
               "\(name): \(writable) is writable")
    }
    expect(text.contains("(subpath \"\(configRoot.appendingPathComponent("runtime/\(name)").path)\")"),
           "\(name): its own redirected home is writable")
    // The configuration root as a whole never becomes writable: that entry is
    // what would let an agent overwrite the thread database (06 §3.6).
    expect(!text.contains("(subpath \"\(configRoot.path)\")"),
           "\(name): the whole configuration root is not writable")
    // Secrets stay unreadable, with the public trust store re-allowed after.
    for expression in [#"/\.ssh/"#, #"/\.env"#, #"/\.config/gh/"#, #"/\.git-credentials"#] {
        expect(text.contains("(regex #\"\(expression)\")"), "\(name): \(expression) is unreadable")
    }
    guard let denyRead = text.range(of: "(deny file-read*"),
          let trustStore = text.range(of: "(subpath \"/etc/ssl\")") else {
        expect(false, "\(name): the profile has a read denial and a trust-store re-allow")
        continue
    }
    expect(denyRead.lowerBound < trustStore.lowerBound,
           "\(name): the trust store is re-allowed after the secret denial, not before")
    // personas/ is never writable, on any runtime, even though it sits inside
    // a configuration root whose subfolders are granted (branch 11).
    guard let allowWrite = text.range(of: "(allow file-write*"),
          let personas = text.range(of: "(subpath \"\(configRoot.appendingPathComponent("personas").path)\")") else {
        expect(false, "\(name): the profile protects the personas folder")
        continue
    }
    expect(allowWrite.upperBound < personas.lowerBound,
           "\(name): the personas denial comes after the writable block, so the kernel honours it")
}

// Network: OpenCode stays on loopback and leaves through the egress proxy;
// Codex and Claude Code must reach their own vendor (06 §3.6).
expect(openCodeText.contains("(deny network*)"), "opencode: non-loopback connections are denied")
expect(openCodeText.contains(#"(allow network-outbound (remote ip "localhost:*"))"#),
       "opencode: loopback stays open")
expect(!codexText.contains("(deny network*)"), "codex: the network is open, it must reach OpenAI")
expect(!claudeText.contains("(deny network*)"), "claude: the network is open, it must reach Anthropic")

// Per-runtime writable additions and the files that stay protected inside them.
expect(codexText.contains("(subpath \"\(home)/.codex\")"), "codex: ~/.codex is writable")
for locked in ["\(home)/.codex/config.toml", "\(home)/.codex/AGENTS.md", "\(home)/.codex/skills"] {
    expect(codexText.contains("(subpath \"\(locked)\")") || codexText.contains("(literal \"\(locked)\")"),
           "codex: \(locked) is named in the profile")
    if let allow = codexText.range(of: "(allow file-write*"),
       let mention = codexText.range(of: locked, range: allow.upperBound..<codexText.endIndex) {
        expect(codexText.range(of: "(deny file-write*", range: allow.upperBound..<mention.lowerBound) != nil,
               "codex: \(locked) is denied after the writable block")
    } else {
        expect(false, "codex: \(locked) appears after the writable block")
    }
}
for writable in ["\(home)/.claude", "\(home)/.cache", "\(home)/.npm", "\(home)/Library/Caches"] {
    expect(claudeText.contains("(subpath \"\(writable)\")"), "claude: \(writable) is writable")
}
expect(claudeText.contains("\(home)/.claude.json"), "claude: ~/.claude.json is writable")
for locked in ["\(home)/.claude/CLAUDE.md", "\(home)/.claude/skills", "\(home)/.claude/agents",
               "\(home)/.claude/commands", "\(home)/.claude/hooks"] {
    expect(claudeText.contains(locked), "claude: \(locked) is named in the profile")
}
expect(claudeText.contains(#"\.claude/settings"#),
       "claude: the settings files are named as one expression in the profile")
// Claude Code keeps its own sign-in in the login keychain, so that one read
// is given back after the secret denial; the other two runtimes never get it.
guard let claudeDeny = claudeText.range(of: "(deny file-read*"),
      let keychain = claudeText.range(of: "\(home)/Library/Keychains") else {
    expect(false, "claude: the login keychain is re-allowed")
    exit(failures == 0 ? 0 : 1)
}
expect(claudeDeny.upperBound < keychain.lowerBound,
       "claude: the login keychain is re-allowed after the secret denial")
expect(!codexText.contains("\(home)/Library/Keychains"),
       "codex: the login keychain stays unreadable")
expect(!openCodeText.contains("\(home)/Library/Keychains"),
       "opencode: the login keychain stays unreadable")

// The granted-folder correction (06 §3.6): the default entry for the whole
// configuration folder becomes the three subfolders agents legitimately write.
let corrected = profileText(inputs(.opencode, granted: [configRoot.path]))
for replacement in ["projects/general", "thread-scratch", "worktrees"] {
    expect(corrected.contains("(subpath \"\(configRoot.appendingPathComponent(replacement).path)\")"),
           "the granted configuration folder becomes \(replacement)")
}
expect(!corrected.contains("(subpath \"\(configRoot.path)\")"),
       "the granted configuration folder itself is not writable")

// Trust profile observe: no project and no granted folder is writable, while
// the runtime's own home and the thread's scratch still are.
let observed = profileText(inputs(.claude, profile: .observe))
expect(!observed.contains("(subpath \"\(project.path)\")"),
       "observe: the project folder is not writable")
expect(!observed.contains("(subpath \"\(grantedFolder.path)\")"),
       "observe: a granted folder is not writable")
expect(observed.contains("(subpath \"\(folders.scratchDirectory.path)\")"),
       "observe: the thread's scratch folder stays writable")

// Run commands off: OpenCode is stopped by the kernel (the other two refuse
// to start at all, which the launcher suite pins).
var closedDial = AgentCapabilityDial()
closedDial.runCommands = false
expect(profileText(inputs(.opencode, dial: closedDial)).contains("(deny process-exec*)"),
       "run commands off: the kernel refuses to exec")
expect(!openCodeText.contains("(deny process-exec*)"),
       "run commands on: exec is not denied")

// ── The profile file itself ──────────────────────────────────────────────

let prefix = try RuntimeRuleFile.launchPrefix(inputs(.codex), threadID: "thread-a")
expect(prefix.first == "/usr/bin/sandbox-exec", "the launch prefix applies sandbox-exec first")
expect(prefix.count == 3 && prefix[1] == "-f", "the launch prefix is sandbox-exec -f <profile>")
let writtenProfile = prefix.count == 3 ? prefix[2] : ""
expect(manager.fileExists(atPath: writtenProfile), "the profile file was written")
// The rule file must not live inside anything the confined process may write,
// or a turn could rewrite its own next confinement.
let writableRoots = [project.path, grantedFolder.path, folders.scratchDirectory.path,
                     configRoot.appendingPathComponent("runtime").path]
for root in writableRoots {
    expect(!writtenProfile.hasPrefix(root + "/"),
           "the profile file is not inside the writable root \(root)")
}
expect(writtenProfile.hasPrefix(configRoot.path + "/"),
       "the profile file is inside the configuration root")

// ── Real escape attempts through the real kernel ─────────────────────────

func run(_ policy: AgentSandboxPolicy, _ script: String, label: String) -> Int32 {
    let profileURL = scratch.appendingPathComponent("drill-\(UUID().uuidString).sb")
    guard let argv = try? AgentSandbox.launchPrefix(policy: policy, profileURL: profileURL),
          !argv.isEmpty else {
        expect(false, "\(label): sandbox-exec is available")
        return -1
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst()) + ["/bin/sh", "-c", script]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        expect(false, "\(label): the drill process started (\(error))")
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

guard AgentSandbox.isAvailable else {
    FileHandle.standardError.write(Data("not ok - /usr/bin/sandbox-exec is missing\n".utf8))
    exit(1)
}

for runtime in AgentRuntimeKind.allCases {
    let policy = RuntimeRuleFile.policy(inputs(runtime))
    let name = runtime.rawValue
    let inside = project.appendingPathComponent("written-by-\(name).txt").path
    expect(run(policy, "echo hi > \(inside)", label: "\(name) writes inside the project") == 0,
           "\(name): a write inside the project folder succeeds")
    expect(manager.fileExists(atPath: inside), "\(name): the file is really there")
    expect(run(policy, "echo hi > \(outside.path)/outside-\(name).txt",
               label: "\(name) writes outside") != 0,
           "\(name): a write outside every granted root fails")
    expect(!manager.fileExists(atPath: "\(outside.path)/outside-\(name).txt"),
           "\(name): nothing was written outside")
    expect(run(policy, "cat \(outside.path)/.ssh/config", label: "\(name) reads a secret") != 0,
           "\(name): reading a .ssh file fails")
    // The denial must be the secret rule, not a profile that denies every read.
    expect(run(policy, "cat \(outside.path)/plain.txt", label: "\(name) reads a plain file") == 0,
           "\(name): reading an ordinary file outside still works")
    expect(run(policy, "cat \(project.path)/existing.txt", label: "\(name) reads the project") == 0,
           "\(name): reading the project's own file works")
    let personaFile = configRoot.appendingPathComponent("personas/flora/persona.md")
    try? manager.createDirectory(at: personaFile.deletingLastPathComponent(),
                                 withIntermediateDirectories: true)
    try? Data("instructions\n".utf8).write(to: personaFile)
    expect(run(policy, "echo rewritten > \(personaFile.path)",
               label: "\(name) rewrites its persona") != 0,
           "\(name): an agent cannot rewrite its own persona file")
    expect((try? String(contentsOf: personaFile, encoding: .utf8)) == "instructions\n",
           "\(name): the persona file is unchanged")
}

if failures == 0 {
    print("runtime rule file: \(checks) checks passed")
    exit(0)
}
FileHandle.standardError.write(Data("not ok - \(failures) of \(checks) checks failed\n".utf8))
exit(1)
