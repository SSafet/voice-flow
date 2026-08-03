import Foundation

/// The OS-enforced boundary around the agent runtime (ticket VF-59).
///
/// OpenCode's own permission rules match on tool names and command text, which
/// a model bypasses the moment it writes a script instead of typing a command.
/// So containment lives here instead: a Seatbelt profile wrapping the runtime
/// process. macOS applies it to every descendant — a shell the agent spawns, a
/// Python file it writes and runs, an MCP server, a detached daemon — and no
/// descendant can drop it. Denials surface as EPERM at the syscall, not as a
/// prompt the model can argue with.
///
/// Everything not named here stays allowed on purpose. The profile denies the
/// four things that are actually dangerous and gets out of the way otherwise.
struct AgentSandboxPolicy: Equatable {
    /// Roots the agent may write to — the user's granted workspaces.
    var workspaceRoots: [URL]
    /// Runtime-private roots (its XDG home, logs, generated config).
    var runtimeRoots: [URL]
    /// Additional scratch roots that must stay writable for tooling (TMPDIR).
    var temporaryRoots: [URL]
    /// When false the kernel refuses to exec anything — the dial's "run
    /// commands" switch, enforced below the model rather than asked of it.
    var allowShell: Bool
    /// Egress always leaves through the loopback proxy; this only decides
    /// whether the proxy is wired up at all (see `OpenCodeSupervisor`).
    var allowNetwork: Bool

    /// Path fragments that stay unreadable even inside a granted workspace, so
    /// granting a repo never grants its credentials. Matched as SBPL regexes
    /// against the resolved path.
    static let secretPathExpressions = [
        #"/\.env"#,
        #"/\.ssh/"#,
        #"/\.aws/"#,
        #"/\.gnupg/"#,
        #"/\.netrc"#,
        #"/\.npmrc"#,
        #"/id_(rsa|dsa|ecdsa|ed25519)"#,
        #"\.pem$"#,
        #"\.p12$"#,
        #"\.keychain(-db)?$"#,
        #"/credentials(\.json)?$"#,
        #"/\.git-credentials"#,
    ]

    /// Renders the profile in Seatbelt Profile Language.
    ///
    /// Shape matters: `(allow default)` first keeps the thousand uninteresting
    /// operations (mach lookups, sysctl reads, signals) working, then each
    /// concern is denied broadly and re-allowed narrowly. SBPL resolves to the
    /// *last* matching rule, so the re-allow lines must follow their deny.
    func profileText() -> String {
        var lines = [
            "(version 1)",
            "(allow default)",
            "",
            "; ---- writes: denied everywhere, then re-allowed per granted root",
            "(deny file-write*)",
        ]

        let writable = (runtimeRoots + workspaceRoots + temporaryRoots)
            .flatMap { Self.matchablePaths(for: $0) }
        if !writable.isEmpty {
            lines.append("(allow file-write*")
            for path in Set(writable).sorted() {
                lines.append("  (subpath \(Self.quote(path)))")
            }
            lines.append(")")
        }
        // Terminals, pipes and /dev/null are not user data; tooling breaks
        // without them and nothing is at risk.
        lines.append(#"(allow file-write* (regex #"^/dev/"))"#)

        lines.append(contentsOf: [
            "",
            "; ---- secrets: unreadable even inside a granted workspace",
            "(deny file-read*",
        ])
        for expression in Self.secretPathExpressions {
            lines.append("  (regex #\"\(expression)\")")
        }
        lines.append(")")

        lines.append(contentsOf: [
            "",
            "; ---- network: loopback only.",
            "; Real egress leaves through Voice Flow's proxy on 127.0.0.1, so a",
            "; direct connection is always something trying to avoid the log.",
            "; `(local ip)` would match outbound too and silently reopen this —",
            "; the outbound/bind split is deliberate.",
            "(deny network*)",
            #"(allow network-outbound (remote ip "localhost:*"))"#,
            #"(allow network-bind (local ip "localhost:*"))"#,
            "(allow network-outbound (remote unix-socket))",
        ])

        if !allowShell {
            lines.append(contentsOf: [
                "",
                "; ---- dial: run commands is off, so nothing may exec at all",
                "(deny process-exec*)",
            ])
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Every spelling of a path that Seatbelt might match against.
    ///
    /// Seatbelt evaluates the *canonical* path, and on macOS the obvious API
    /// resolves the wrong way: `URL.resolvingSymlinksInPath()` turns
    /// `/private/var/folders/…` into `/var/folders/…`, which is the symlink,
    /// not the target. A rule written that way never fires, and TMPDIR — where
    /// build tools and even shell heredocs write — silently stays read-only.
    /// So canonicalize with `realpath(3)` and emit both spellings.
    static func matchablePaths(for url: URL) -> [String] {
        let given = url.standardizedFileURL.path
        var results = [given]
        if let canonical = canonicalPath(given), canonical != given {
            results.append(canonical)
        }
        return results
    }

    /// `realpath` fails on a path that doesn't exist yet, which a granted root
    /// legitimately may not, so resolve the nearest existing ancestor and
    /// re-attach the remainder.
    private static func canonicalPath(_ path: String) -> String? {
        var existing = path
        var trailing: [String] = []
        while !FileManager.default.fileExists(atPath: existing), existing != "/" {
            trailing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { return nil }
        }
        guard let resolved = realpath(existing, nil) else { return nil }
        defer { free(resolved) }
        let base = String(cString: resolved)
        return trailing.isEmpty
            ? base
            : ([base] + trailing).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// SBPL string literals are C-like: only backslash and quote need escaping.
    private static func quote(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

struct AgentSandboxSnapshot: Equatable {
    var workspaceRoots: [String]
    var dial: AgentCapabilityDial
    var egressAllowedHosts: [String]
    var egressBlockedHosts: [String]

    init(workspaceRoots: [String] = [],
         dial: AgentCapabilityDial = AgentCapabilityDial(),
         egressAllowedHosts: [String] = [],
         egressBlockedHosts: [String] = []) {
        self.workspaceRoots = workspaceRoots
        self.dial = dial
        self.egressAllowedHosts = egressAllowedHosts
        self.egressBlockedHosts = egressBlockedHosts
    }
}

/// Keeps the runtime process layer independent of `UserSettings`, mirroring
/// `ModelGatewayCredentials`, so the supervisor's containment and transport
/// contracts stay compilable and testable without the full app.
final class AgentSandboxSettings {
    static let shared = AgentSandboxSettings()
    private let lock = NSLock()
    private var provider: () -> AgentSandboxSnapshot = { AgentSandboxSnapshot() }

    func configure(_ value: @escaping () -> AgentSandboxSnapshot) {
        lock.withLock { provider = value }
    }

    func snapshot() -> AgentSandboxSnapshot {
        lock.withLock { provider() }
    }
}

enum AgentSandbox {
    static let executable = "/usr/bin/sandbox-exec"

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    /// Writes the profile and returns the argv prefix that applies it.
    ///
    /// Returns nil only when `sandbox-exec` is missing entirely. Callers treat
    /// that as fatal rather than launching unconfined: a runtime that silently
    /// loses containment is worse than one that fails to start.
    static func launchPrefix(policy: AgentSandboxPolicy,
                             profileURL: URL) throws -> [String]? {
        guard isAvailable else { return nil }
        try FileManager.default.createDirectory(
            at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(policy.profileText().utf8).write(to: profileURL, options: .atomic)
        return [executable, "-f", profileURL.path]
    }
}
