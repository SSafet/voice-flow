import Foundation

/// The shape of a process that is about to be started under one kernel rule
/// file (06 §3.6).
///
/// `executableURL` is always `/usr/bin/sandbox-exec`: the kernel holds the
/// boundary before the runtime's first instruction, so no runtime ever starts
/// unconfined.
struct RuntimeProcessPlan: Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let currentDirectory: URL
    let profilePath: String
    let binaryPath: String
}

enum RuntimeLauncher {
    /// The refusals of this package, in one order: the sandbox, then the
    /// installation, then the version, then the person's switches, then the
    /// sign-in. One refusal, and it is the one that is true first.
    static func preflight(runtime: AgentRuntimeKind, dial: AgentCapabilityDial,
                          installedVersion: String?, signedIn: Bool,
                          sandbox: SandboxHealth, environment: [String: String]) throws {
        guard sandbox.working else {
            throw RuntimeLaunchError.sandboxUnavailable(sandbox.detail ?? "sandbox-exec failed")
        }
        guard let version = installedVersion else {
            throw RuntimeLaunchError.notInstalled(runtime)
        }
        if runtime == .codex {
            let range = RuntimeVersionRange.codex(environment: environment)
            guard range.contains(version) else {
                throw RuntimeLaunchError(
                    code: .runtimeUnavailable,
                    message: "\(runtime.label) version \(version) is not supported; "
                        + "Voice Flow supports \(range.text)",
                    retryable: false)
            }
        }
        // OpenCode never refuses for a switch: its two switches are kernel
        // rules. Codex and Claude Code refuse to start at all.
        if runtime == .codex || runtime == .claude {
            guard dial.runCommands else {
                throw RuntimeLaunchError.switchOff(runtime, switchName: "run commands")
            }
            guard dial.reachNetwork else {
                throw RuntimeLaunchError.switchOff(runtime, switchName: "reach network")
            }
        }
        guard signedIn else {
            throw RuntimeLaunchError.notSignedIn(runtime)
        }
    }

    /// Builds the one plan shape every runtime shares: the rule file first,
    /// the runtime binary next, the runtime's own arguments last. The profile
    /// comes from `RuntimeRuleFile.launchPrefix`, so the file is written and
    /// `sandbox-exec`'s presence is checked before a process exists.
    static func plan(binaryPath: String, rules: RuntimeRuleFile.Inputs, threadID: String,
                     arguments: [String], environment: [String: String]) throws -> RuntimeProcessPlan {
        _ = try RuntimeRuleFile.launchPrefix(rules, threadID: threadID)
        let profilePath = RuntimeRuleFile.profileURL(rules, threadID: threadID).path
        return RuntimeProcessPlan(
            executableURL: URL(fileURLWithPath: AgentSandbox.executable),
            arguments: ["-f", profilePath, binaryPath] + arguments,
            environment: environment,
            currentDirectory: rules.folders.workingDirectory,
            profilePath: profilePath,
            binaryPath: binaryPath)
    }
}
