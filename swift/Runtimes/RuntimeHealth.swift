import Foundation

/// The sandbox health line and the runtime status this Mac reports as its
/// home's `runtimes` (06 §3.6).
///
/// The sandbox is checked first and a failed probe makes every runtime that
/// needs it unavailable: nothing ever runs unconfined silently. The line is
/// carried beside the runtime list because `TPHomeRuntime` has no field for it.
struct SandboxHealth: Equatable {
    let working: Bool
    let detail: String?

    var line: String {
        working ? "sandbox: working" : "sandbox: failed — \(detail ?? "unknown error")"
    }
}

struct RuntimeInstallation: Equatable {
    let kind: AgentRuntimeKind
    let binaryPath: String?
    let version: String?
    let signedIn: Bool
}

struct RuntimeStatusReport: Equatable {
    let runtimes: [TPHomeRuntime]
    let sandbox: SandboxHealth
}

enum RuntimeHealth {
    /// Starts a trivial program under the rule file. `working` is whether it
    /// exited zero; otherwise the detail is the system's own error.
    static func probeSandbox(profileURL: URL) -> SandboxHealth {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: AgentSandbox.executable)
        process.arguments = ["-f", profileURL.path, "/usr/bin/true"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return SandboxHealth(working: false, detail: error.localizedDescription)
        }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return SandboxHealth(working: true, detail: nil) }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "sandbox-exec exited with \(process.terminationStatus)"
        return SandboxHealth(working: false, detail: (text?.isEmpty == false) ? text : fallback)
    }

    /// One `TPHomeRuntime` per installation, with the first real reason named
    /// in the launcher's own order: sandbox, installation, version, sign-in.
    static func report(_ installations: [RuntimeInstallation], sandbox: SandboxHealth,
                       codexRange: RuntimeVersionRange = .codexDefault) -> RuntimeStatusReport {
        let runtimes = installations.map { installation in
            let detail = unavailableDetail(installation, sandbox: sandbox, codexRange: codexRange)
            return TPHomeRuntime(
                available: detail == nil,
                detail: detail,
                kind: kind(for: installation.kind),
                version: installation.version)
        }
        return RuntimeStatusReport(runtimes: runtimes, sandbox: sandbox)
    }

    private static func unavailableDetail(_ installation: RuntimeInstallation,
                                          sandbox: SandboxHealth,
                                          codexRange: RuntimeVersionRange) -> String? {
        guard sandbox.working else {
            return "the sandbox is unavailable: \(sandbox.detail ?? "unknown error")"
        }
        guard let binary = installation.binaryPath, !binary.isEmpty else {
            return "\(installation.kind.label) is not installed on this Mac"
        }
        if installation.kind == .codex {
            guard let version = installation.version else {
                return "\(installation.kind.label) has no readable version"
            }
            guard codexRange.contains(version) else {
                return "\(installation.kind.label) version \(version) is not supported; "
                    + "Voice Flow supports \(codexRange.text)"
            }
        }
        guard installation.signedIn else {
            return "\(installation.kind.label) is not signed in; sign in to the runtime first"
        }
        return nil
    }

    private static func kind(for runtime: AgentRuntimeKind) -> TPHomeRuntimeKind {
        switch runtime {
        case .codex: return .codex
        case .claude: return .claude
        case .opencode: return .opencode
        }
    }
}
