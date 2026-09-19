import Foundation

// The temporary command-line caller for work package V3 (06 §8, item 6).
// It drives one turn per runtime through the same launcher and normaliser the
// app uses, so the design lead can observe a real turn before V6's server can.
// It is compiled by scripts/runtime-turn.sh and is not part of the app target.

func vflog(_ message: String) {}

enum CallerError: LocalizedError {
    case usage(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .usage(let detail): return "runtime-turn: \(detail)"
        case .unsupported(let detail): return "runtime-turn: \(detail)"
        }
    }
}

struct Arguments {
    var runtime: AgentRuntimeKind = .codex
    var project: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var prompt: String = ""
    var persona: URL?
    var trust: AgentTrustProfile = .workspace
    var model: String?
    var toolEndpoint: URL = URL(string: "http://127.0.0.1:8792/mcp")!
    var toolToken: String = ""

    static func parse(_ raw: [String]) throws -> Arguments {
        var result = Arguments()
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < raw.count else { throw CallerError.usage("\(flag) needs a value") }
            return raw[index]
        }
        while index < raw.count {
            switch raw[index] {
            case "--runtime":
                let name = try value("--runtime")
                guard let kind = AgentRuntimeKind(rawValue: name) else {
                    throw CallerError.usage("unknown runtime \(name)")
                }
                result.runtime = kind
            case "--project":
                result.project = URL(fileURLWithPath: try value("--project"))
            case "--prompt":
                result.prompt = try value("--prompt")
            case "--persona":
                result.persona = URL(fileURLWithPath: try value("--persona"))
            case "--trust":
                let name = try value("--trust")
                guard let profile = AgentTrustProfile(rawValue: name) else {
                    throw CallerError.usage("unknown trust profile \(name)")
                }
                result.trust = profile
            case "--model":
                result.model = try value("--model")
            case "--tool-endpoint":
                let text = try value("--tool-endpoint")
                guard let url = URL(string: text) else {
                    throw CallerError.usage("bad tool endpoint \(text)")
                }
                result.toolEndpoint = url
            case "--tool-token":
                result.toolToken = try value("--tool-token")
            default:
                throw CallerError.usage("unknown argument \(raw[index])")
            }
            index += 1
        }
        guard !result.prompt.isEmpty else { throw CallerError.usage("--prompt is required") }
        return result
    }
}

func emit(_ event: RuntimeEvent) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(event), let text = String(data: data, encoding: .utf8) {
        print(text)
        fflush(stdout)
    } else {
        print(#"{"event":"unknown"}"#)
    }
}

func binaryPath(for runtime: AgentRuntimeKind) -> String? {
    switch runtime {
    case .codex:
        let candidates = [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            NSHomeDirectory() + "/.local/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    case .claude:
        let candidates = [
            NSHomeDirectory() + "/.local/bin/claude", NSHomeDirectory() + "/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    case .opencode:
        return nil
    }
}

func makeFolders(_ arguments: Arguments) -> RuntimeFolders {
    let scratch = RuntimeFolders.scratchDirectory(
        threadID: "caller-\(arguments.runtime.rawValue)",
        configRoot: VoiceFlowPaths.shared.configRoot)
    return RuntimeFolders(
        workingDirectory: arguments.project,
        personaDirectory: arguments.persona,
        scratchDirectory: scratch)
}

func makeRules(_ arguments: Arguments, folders: RuntimeFolders) -> RuntimeRuleFile.Inputs {
    RuntimeRuleFile.Inputs(
        runtime: arguments.runtime, trustProfile: arguments.trust, folders: folders,
        projectRoots: [arguments.project], grantedRoots: [arguments.project.path],
        runtimeHome: FileManager.default.homeDirectoryForCurrentUser,
        dial: AgentCapabilityDial(),
        configRoot: VoiceFlowPaths.shared.configRoot)
}

func runCodex(_ arguments: Arguments, folders: RuntimeFolders) throws {
    guard let binary = binaryPath(for: .codex) else {
        throw RuntimeLaunchError.notInstalled(.codex)
    }
    let rules = makeRules(arguments, folders: folders)
    let plan = try CodexLaunch.plan(
        binaryPath: binary, rules: rules, threadID: "caller-codex",
        toolEndpoint: arguments.toolEndpoint, token: arguments.toolToken)
    let normaliser = CodexNormaliser()
    let process = Process()
    process.executableURL = plan.executableURL
    process.arguments = plan.arguments
    process.environment = plan.environment
    process.currentDirectoryURL = plan.currentDirectory
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    for line in output.fileHandleForReading.readDataToEndOfFile().split(separator: 0x0A) {
        for event in normaliser.accept(Data(line)) { emit(event) }
    }
    for event in normaliser.finish(.completed(text: nil, usage: nil)) { emit(event) }
}

func runClaude(_ arguments: Arguments, folders: RuntimeFolders) throws {
    guard let binary = binaryPath(for: .claude) else {
        throw RuntimeLaunchError.notInstalled(.claude)
    }
    let rules = makeRules(arguments, folders: folders)
    let plan = try ClaudeCodeLaunch.plan(
        binaryPath: binary, rules: rules, folders: folders,
        isFolderProject: true, trustProfile: arguments.trust, resumeSessionID: nil,
        newSessionID: "caller-claude", model: arguments.model, reasoningEffort: nil,
        toolEndpoint: arguments.toolEndpoint, token: arguments.toolToken,
        instructions: "")
    let normaliser = ClaudeCodeNormaliser()
    let process = Process()
    process.executableURL = plan.executableURL
    process.arguments = plan.arguments
    process.environment = plan.environment
    process.currentDirectoryURL = plan.currentDirectory
    let stdin = Pipe()
    let output = Pipe()
    process.standardInput = stdin
    process.standardOutput = output
    process.standardError = output
    try process.run()
    try? stdin.fileHandleForWriting.write(contentsOf: Data(
        (#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"\#(arguments.prompt)"}]}}"# + "\n").utf8))
    try? stdin.fileHandleForWriting.close()
    process.waitUntilExit()
    for line in output.fileHandleForReading.readDataToEndOfFile().split(separator: 0x0A) {
        for event in normaliser.accept(Data(line)) { emit(event) }
    }
    for event in normaliser.finish(.completed(text: nil, usage: nil)) { emit(event) }
}

do {
    let arguments = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
    let folders = makeFolders(arguments)
    let installedVersion = binaryPath(for: arguments.runtime).flatMap {
        RuntimeVersionCache().version(ofBinaryAt: $0)
    }
    let signedIn = arguments.runtime != .codex
        || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/auth.json")
    let sandboxProfile = RuntimeRuleFile.profileURL(makeRules(arguments, folders: folders), threadID: "caller-probe")
    let sandbox = RuntimeHealth.probeSandbox(profileURL: sandboxProfile)
    try RuntimeLauncher.preflight(
        runtime: arguments.runtime, dial: AgentCapabilityDial(),
        installedVersion: installedVersion, signedIn: signedIn,
        sandbox: sandbox, environment: ProcessInfo.processInfo.environment)
    switch arguments.runtime {
    case .codex: try runCodex(arguments, folders: folders)
    case .claude: try runClaude(arguments, folders: folders)
    case .opencode:
        throw CallerError.unsupported(
            "OpenCode turns run through the supervised server, which V6's engine owns")
    }
} catch let error as RuntimeLaunchError {
    FileHandle.standardError.write(Data("\(error.message) (\(error.code.rawValue))\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
