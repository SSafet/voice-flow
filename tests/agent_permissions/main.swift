import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

expect(AgentPermissionPolicy(profile: .observe).decision(for: .computerObserve) == .allow,
       "observe screenshot should be allowed")
expect(AgentPermissionPolicy(profile: .observe).decision(for: .computerControl) == .deny,
       "observe control should be denied")
expect(AgentPermissionPolicy(profile: .workspace).decision(for: .computerControl) == .ask,
       "workspace control should ask")
expect(AgentPermissionPolicy(profile: .unattended).decision(for: .userAsk) == .deny,
       "unattended runs cannot block on a user ask")
let overridden = AgentPermissionPolicy(
    profile: .workspace, overrides: [.computerControl: .allow])
expect(overridden.decision(for: .computerControl) == .allow, "explicit override was ignored")

let runtimePermissions = AgentPermissionPolicy(profile: .workspace)
    .openCodeConfiguration(
        selectedSkills: ["selected"],
        readableExternalRoots: [VoiceFlowPaths.shared.directory("captures")])
let skillRules = runtimePermissions["skill"] as? [String: String]
expect(skillRules?["*"] == "deny" && skillRules?["selected"] == "allow",
       "skill permissions do not deny-by-default")
expect(runtimePermissions["voiceflow_*"] as? String == "allow",
       "Voice Flow tools are not admitted")

let mcp = AgentMCPAllowlist.configuration(
    selections: [AgentMCPSelection(server: "github", enabledTools: ["search-code"])],
    knownServers: [
        "github": ["type": "remote", "url": "https://example.invalid"],
        "slack": ["type": "remote", "url": "https://example.invalid"],
    ])
let servers = mcp["mcp"] as? [String: [String: Any]]
let permissions = mcp["permission"] as? [String: String]
expect(servers?["github"]?["enabled"] as? Bool == true, "selected MCP disabled")
expect(servers?["slack"]?["enabled"] as? Bool == false, "unselected MCP enabled")
expect(permissions?["github_search_code"] == "allow", "selected MCP tool denied")
expect(permissions?["github_*"] == "deny", "MCP server lacks default deny")

let auditURL = VoiceFlowPaths.shared.file("audit-test.jsonl")
let canary = "api_key=sk-live-abcdefghijklmnop"
AgentSecurityAudit(url: auditURL).append(
    conversationID: "c", runID: "r", action: "memory",
    decision: .deny, detail: canary)
let audit = try String(contentsOf: auditURL)
expect(!audit.contains("sk-live-abcdefghijklmnop") && audit.contains("REDACTED"),
       "security audit leaked a secret")
print("agent permission tests passed")
