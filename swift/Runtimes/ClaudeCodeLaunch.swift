import Foundation

/// How `claude -p` is started (06 §3.6).
///
/// `RuntimeRuleFile` renders the one kernel rule file that confines every
/// runtime; this type only describes Claude Code's own arguments and
/// environment. The stream-json shape stays; what is added is which setting
/// sources apply, the permission mode the trust profile maps to, one strict
/// MCP server that can reach VoiceFlow's tools, the persona and scratch
/// folders, and a four-hour tool limit so a call can wait for a person.
enum ClaudeCodeLaunch {
    static let toolTimeoutMilliseconds = 14_400_000
    static let serverName = "voiceflow"

    /// Observe plans instead of acting; workspace bypasses Claude Code's own
    /// confirmations because the kernel rule file is the boundary; an
    /// unattended turn cannot answer a confirmation, so it raises none.
    static func permissionMode(for profile: AgentTrustProfile) -> String {
        switch profile {
        case .observe: return "plan"
        case .workspace, .unattended: return "bypassPermissions"
        }
    }

    /// A folder project applies the repository's own instructions, skills and
    /// settings; a General-project thread applies only the person's own.
    static func settingSources(isFolderProject: Bool) -> String {
        isFolderProject ? "user,project,local" : "user"
    }

    static func mcpConfig(endpoint: URL, token: String) -> [String: Any] {
        [
            "mcpServers": [
                serverName: [
                    "type": "http",
                    "url": endpoint.absoluteString,
                    "headers": ["Authorization": "Bearer \(token)"],
                ],
            ],
        ]
    }

    static func plan(binaryPath: String, rules: RuntimeRuleFile.Inputs, folders: RuntimeFolders,
                     isFolderProject: Bool, trustProfile: AgentTrustProfile, resumeSessionID: String?,
                     newSessionID: String, model: String?, reasoningEffort: String?,
                     toolEndpoint: URL, token: String, instructions: String) throws -> RuntimeProcessPlan {
        var arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--setting-sources", settingSources(isFolderProject: isFolderProject),
            "--permission-mode", permissionMode(for: trustProfile),
            "--strict-mcp-config",
            "--mcp-config", try encoded(mcpConfig(endpoint: toolEndpoint, token: token)),
        ]
        var addedFolders: [String] = []
        if let persona = folders.personaDirectory { addedFolders.append(persona.path) }
        addedFolders.append(folders.scratchDirectory.path)
        arguments.append("--add-dir")
        arguments.append(contentsOf: addedFolders)
        if let resumeSessionID {
            arguments.append(contentsOf: ["--resume", resumeSessionID])
        } else {
            arguments.append(contentsOf: ["--session-id", newSessionID])
        }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            arguments.append(contentsOf: ["--model", model])
        }
        if let normalized = AgentReasoningEffort.normalized(reasoningEffort) {
            arguments.append(contentsOf: ["--effort", normalized == "minimal" ? "low" : normalized])
        }
        if !instructions.isEmpty {
            arguments.append(contentsOf: ["--append-system-prompt", instructions])
        }
        var environment = ProcessInfo.processInfo.environment
        environment["MCP_TOOL_TIMEOUT"] = String(toolTimeoutMilliseconds)
        return try RuntimeLauncher.plan(
            binaryPath: binaryPath, rules: rules, threadID: newSessionID,
            arguments: arguments, environment: environment)
    }

    private static func encoded(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeLaunchError(
                code: .runtimeUnavailable,
                message: "VoiceFlow's tool configuration could not be encoded",
                retryable: false)
        }
        return text
    }
}
