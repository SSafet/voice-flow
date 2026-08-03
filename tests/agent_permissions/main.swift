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

// VF-59: the OpenCode permission map is UX, not the boundary — the sandbox is.
// It stays permissive, and only the dial closes anything.
let runtimePermissions = AgentPermissionPolicy(profile: .workspace)
    .openCodeConfiguration(selectedSkills: [], readableExternalRoots: [])
expect(runtimePermissions["voiceflow_*"] as? String == "allow",
       "Voice Flow tools are not admitted")
expect(runtimePermissions["bash"] as? String == "allow",
       "bash should not prompt once the kernel contains it")
expect(runtimePermissions["external_directory"] as? String == "allow",
       "reads outside the project root are no longer gated here")

let restricted = AgentPermissionPolicy(
    profile: .workspace,
    dial: AgentCapabilityDial(runCommands: false, reachNetwork: false, controlScreen: false))
expect(restricted.openCodeConfiguration(
        selectedSkills: [], readableExternalRoots: [])["bash"] as? String == "deny",
       "dial did not close bash")
expect(restricted.decision(for: .shell) == .deny, "dial did not close the shell capability")
expect(restricted.decision(for: .computerControl) == .deny,
       "dial did not close screen control")
expect(AgentPermissionPolicy(
        profile: .workspace,
        overrides: [.computerControl: .allow],
        dial: AgentCapabilityDial(controlScreen: false))
        .decision(for: .computerControl) == .allow,
       "an explicit per-run override must still win over the dial default")

// The profile text is the actual security artifact; assert its teeth directly.
let sandbox = AgentSandboxPolicy(
    workspaceRoots: [URL(fileURLWithPath: "/tmp/granted")],
    runtimeRoots: [URL(fileURLWithPath: "/tmp/runtime")],
    temporaryRoots: [], allowShell: true, allowNetwork: true)
let text = sandbox.profileText()
expect(text.contains("(deny file-write*)"), "sandbox does not deny writes by default")
expect(text.contains("(subpath \"/tmp/granted\")"), "granted workspace is not writable")
expect(text.contains("(deny network*)"), "sandbox does not deny network by default")
expect(text.contains("(allow network-outbound (remote ip \"localhost:*\"))"),
       "loopback egress is not permitted")
expect(!text.contains("(allow network* (local ip)"),
       "the (local ip) form silently reopens all egress and must never return")
expect(text.contains(#"/\.ssh/"#) && text.contains(#"/\.env"#),
       "secret shapes are readable")
expect(!text.contains("(deny process-exec*)"), "exec denied while the dial allows commands")
expect(AgentSandboxPolicy(
        workspaceRoots: [], runtimeRoots: [], temporaryRoots: [],
        allowShell: false, allowNetwork: true).profileText()
        .contains("(deny process-exec*)"),
       "dial closed commands but the kernel still permits exec")

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
