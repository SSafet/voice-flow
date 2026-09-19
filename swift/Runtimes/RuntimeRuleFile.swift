import Foundation

/// One kernel rule file for all three runtimes (06 §3.6).
///
/// The runtime differences are inputs — what else is writable, what stays
/// protected inside it, whether the network is open, whether the login keychain
/// can be read — so there is one generator, one policy and one file. The file
/// lives under `<config root>/runtime-rules/`, outside every folder the
/// confined process may write, so a turn can never rewrite its own next
/// confinement.
enum RuntimeRuleFile {
    struct Inputs: Equatable {
        var runtime: AgentRuntimeKind
        var trustProfile: AgentTrustProfile
        var folders: RuntimeFolders
        /// Every registered project's folder and its worktrees.
        var projectRoots: [URL]
        /// The person's setting, uncorrected.
        var grantedRoots: [String]
        /// The runtime's own redirected home.
        var runtimeHome: URL
        var dial: AgentCapabilityDial
        var configRoot: URL
    }

    /// The policy the rule file renders: who may write where, what stays
    /// protected, and whether the kernel refuses to exec.
    static func policy(_ inputs: Inputs) -> AgentSandboxPolicy {
        AgentSandboxPolicy(
            workspaceRoots: RuntimeGrants.writableRoots(inputs),
            runtimeRoots: [],
            temporaryRoots: [],
            allowShell: inputs.dial.runCommands,
            allowNetwork: inputs.dial.reachNetwork,
            protectedWriteSubpaths: RuntimeGrants.protectedSubpaths(inputs),
            protectedWriteExpressions: RuntimeGrants.protectedExpressions(inputs),
            readableExceptions: RuntimeGrants.readableExceptions(inputs),
            allowDirectNetwork: inputs.runtime != .opencode)
    }

    /// `<config root>/runtime-rules/<runtime>-<thread id>.sb`.
    static func profileURL(_ inputs: Inputs, threadID: String) -> URL {
        inputs.configRoot
            .appendingPathComponent("runtime-rules", isDirectory: true)
            .appendingPathComponent("\(inputs.runtime.rawValue)-\(threadID).sb")
    }

    /// Writes the rule file and returns the argv prefix that applies it.
    ///
    /// Throws `RuntimeLaunchError.sandboxUnavailable` when `sandbox-exec` is
    /// missing — never a prefix that would start a program unconfined.
    static func launchPrefix(_ inputs: Inputs, threadID: String) throws -> [String] {
        guard AgentSandbox.isAvailable else {
            throw RuntimeLaunchError.sandboxUnavailable(
                "\(AgentSandbox.executable) is missing")
        }
        let url = profileURL(inputs, threadID: threadID)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(policy(inputs).profileText().utf8).write(to: url, options: .atomic)
        return [AgentSandbox.executable, "-f", url.path]
    }
}
