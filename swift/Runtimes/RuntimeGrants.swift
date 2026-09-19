import Foundation

/// What a confined runtime may write, and what stays protected even inside a
/// root it may write (06 §3.6).
///
/// All three runtimes share one policy shape; the differences are data here,
/// not three code paths. The configuration root is deliberately never a
/// writable entry: a granted whole-configuration-folder is corrected to the
/// subfolders an agent legitimately writes, so an agent can never overwrite the
/// thread database or the persona store.
enum RuntimeGrants {
    /// Subfolders that replace a grant of the whole configuration root.
    static let configGrantReplacements = ["projects/general", "thread-scratch", "worktrees"]
    /// Never writable for any runtime, whatever is granted.
    static let neverWritableConfigFolder = "personas"

    /// Every root the runtime may write.
    static func writableRoots(_ inputs: RuntimeRuleFile.Inputs) -> [URL] {
        var roots: [URL] = []
        // Observe reads only: the project and the person's grants stay out.
        if inputs.trustProfile != .observe {
            roots.append(contentsOf: inputs.projectRoots)
            roots.append(contentsOf: correctedGrantedRoots(inputs))
        }
        roots.append(inputs.folders.scratchDirectory)
        roots.append(inputs.runtimeHome)
        roots.append(contentsOf: runtimeWritableRoots(inputs.runtime))
        roots.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        roots.append(URL(fileURLWithPath: "/private/var/folders", isDirectory: true))
        roots.append(URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        return roots
    }

    /// Paths that stay read-only even inside a root above, rendered after the
    /// writable block so the kernel's last-match rule honours them.
    static func protectedSubpaths(_ inputs: RuntimeRuleFile.Inputs) -> [String] {
        var paths = [inputs.configRoot.appendingPathComponent(neverWritableConfigFolder).path]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch inputs.runtime {
        case .codex:
            paths.append(contentsOf: [
                "\(home)/.codex/config.toml",
                "\(home)/.codex/AGENTS.md",
                "\(home)/.codex/skills",
            ])
        case .claude:
            paths.append(contentsOf: [
                "\(home)/.claude/CLAUDE.md",
                "\(home)/.claude/skills",
                "\(home)/.claude/agents",
                "\(home)/.claude/commands",
                "\(home)/.claude/hooks",
            ])
        case .opencode:
            break
        }
        return paths
    }

    /// A family of protected paths that cannot be named one by one.
    static func protectedExpressions(_ inputs: RuntimeRuleFile.Inputs) -> [String] {
        switch inputs.runtime {
        case .claude: return [#"\.claude/settings"#]
        case .codex, .opencode: return []
        }
    }

    /// Reads re-allowed after the secret denial — only Claude Code, which keeps
    /// its own sign-in in the login keychain.
    static func readableExceptions(_ inputs: RuntimeRuleFile.Inputs) -> [String] {
        switch inputs.runtime {
        case .claude:
            return ["\(FileManager.default.homeDirectoryForCurrentUser.path)/Library/Keychains"]
        case .codex, .opencode:
            return []
        }
    }

    /// The person grants folders as strings; an entry that is not an absolute
    /// path is dropped, and a grant of the whole configuration root becomes its
    /// three writable subfolders.
    private static func correctedGrantedRoots(_ inputs: RuntimeRuleFile.Inputs) -> [URL] {
        var roots: [URL] = []
        let configRootPath = inputs.configRoot.standardizedFileURL.path
        for raw in inputs.grantedRoots {
            guard raw.hasPrefix("/") else { continue }
            let url = URL(fileURLWithPath: raw)
            if url.standardizedFileURL.path == configRootPath {
                for replacement in configGrantReplacements {
                    roots.append(inputs.configRoot.appendingPathComponent(replacement, isDirectory: true))
                }
            } else {
                roots.append(url)
            }
        }
        return roots
    }

    /// What each runtime needs beyond the shared roots to run.
    private static func runtimeWritableRoots(_ runtime: AgentRuntimeKind) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch runtime {
        case .codex:
            return [home.appendingPathComponent(".codex", isDirectory: true)]
        case .claude:
            return [
                home.appendingPathComponent(".claude", isDirectory: true),
                home.appendingPathComponent(".claude.json"),
                home.appendingPathComponent(".cache", isDirectory: true),
                home.appendingPathComponent(".npm", isDirectory: true),
                home.appendingPathComponent("Library/Caches", isDirectory: true),
            ]
        case .opencode:
            return []
        }
    }
}
