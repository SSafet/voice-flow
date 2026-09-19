import Foundation

/// How `codex app-server` is started and told about each turn (06 §3.6).
///
/// VoiceFlow's rule file is the boundary, so Codex is told that something
/// outside already confines it: no `sandbox_mode` and no `writable_roots` of
/// its own, and every turn carries the external-sandbox policy. The tool token
/// travels in the environment, never on the command line.
enum CodexLaunch {
    static let toolTimeoutSeconds = 14_400
    static let tokenEnvironmentKey = "VOICE_FLOW_TOOL_TOKEN"

    static func plan(binaryPath: String, rules: RuntimeRuleFile.Inputs, threadID: String,
                     toolEndpoint: URL, token: String) throws -> RuntimeProcessPlan {
        var environment = ProcessInfo.processInfo.environment
        environment[tokenEnvironmentKey] = token
        let arguments = [
            "app-server",
            "-c", "mcp_servers.voiceflow.url=\(toolEndpoint.absoluteString)",
            "-c", "mcp_servers.voiceflow.bearer_token_env_var=\(tokenEnvironmentKey)",
            "-c", "mcp_servers.voiceflow.required=true",
            "-c", "mcp_servers.voiceflow.tool_timeout_sec=\(toolTimeoutSeconds)",
        ]
        return try RuntimeLauncher.plan(
            binaryPath: binaryPath, rules: rules, threadID: threadID,
            arguments: arguments, environment: environment)
    }

    /// `thread/start` / `thread/resume`: the working folder, never an approval
    /// prompt of Codex's own, and the developer instructions when there are any.
    static func threadParams(cwd: String, resumeThread: String?, instructions: String) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": cwd,
            "approvalPolicy": "never",
        ]
        if !instructions.isEmpty { params["developerInstructions"] = instructions }
        if let resumeThread { params["threadId"] = resumeThread }
        return params
    }

    /// `turn/start`: every turn sends its own `cwd` and states that an outer
    /// sandbox confines the process and its network is open.
    static func turnParams(threadId: String, prompt: String, imagePaths: [String], cwd: String,
                           model: String?, reasoningEffort: String?) -> [String: Any] {
        var input: [[String: Any]] = [["type": "text", "text": prompt]]
        for path in imagePaths {
            input.append(["type": "localImage", "path": path])
        }
        var params: [String: Any] = [
            "threadId": threadId,
            "input": input,
            "cwd": cwd,
            "sandboxPolicy": ["type": "externalSandbox", "networkAccess": "enabled"],
        ]
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            params["model"] = model
        }
        if let effort = reasoningEffort, !effort.isEmpty { params["effort"] = effort }
        return params
    }
}
