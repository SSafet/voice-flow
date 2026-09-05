import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func line(_ json: String) -> Data { Data(json.utf8) }

// ── stream-json decoding (shapes recorded from claude 2.1.209) ──

expect(ClaudeCodeProtocol.decode(line(#"{"type":"system","subtype":"init","session_id":"10fbe309-2e21-4b90-997b-31395c656c3f","model":"claude-opus-4-8[1m]","permissionMode":"plan"}"#))
       == .sessionStarted(sessionID: "10fbe309-2e21-4b90-997b-31395c656c3f", model: "claude-opus-4-8[1m]"),
       "the init line must yield the session id")
expect(ClaudeCodeProtocol.decode(line(#"{"type":"system","subtype":"status","session_id":"x"}"#))
       == .other(type: "system"), "status lines are not session starts")
expect(ClaudeCodeProtocol.decode(line(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"po"}}}"#))
       == .textDelta("po"), "text deltas must stream")
expect(ClaudeCodeProtocol.decode(line(#"{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"Bash","input":{}}}}"#))
       == .toolUse(name: "Bash"), "tool_use starts must surface the tool name")
expect(ClaudeCodeProtocol.decode(line(#"{"type":"stream_event","event":{"type":"message_start"}}"#))
       == .other(type: "stream_event"), "other stream events are ignored")
expect(ClaudeCodeProtocol.decode(line(#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}"#))
       == .assistantText("pong"), "whole assistant messages must be readable for non-streaming CLIs")
expect(ClaudeCodeProtocol.decode(line(#"{"type":"result","subtype":"success","is_error":false,"result":"pong","session_id":"s1","total_cost_usd":0.0123,"num_turns":1,"usage":{"input_tokens":12,"output_tokens":3}}"#))
       == .result(text: "pong", isError: false, sessionID: "s1", inputTokens: 12, outputTokens: 3, costUSD: 0.0123),
       "a success result must carry text, session, usage, and cost")
// Recorded verbatim from a signed-out CLI: the failure arrives as a result
// whose text is the error, flagged is_error — it must never read as a reply.
expect(ClaudeCodeProtocol.decode(line(#"{"type":"result","subtype":"success","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed","session_id":"s1","total_cost_usd":0,"num_turns":1}"#))
       == .result(text: "Failed to authenticate: OAuth session expired and could not be refreshed", isError: true,
                  sessionID: "s1", inputTokens: nil, outputTokens: nil, costUSD: 0),
       "an is_error result must be flagged as an error")
expect(ClaudeCodeProtocol.decode(line(#"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"s1"}"#))
       == .result(text: "Claude Code ended: error_max_turns", isError: true, sessionID: "s1",
                  inputTokens: nil, outputTokens: nil, costUSD: nil),
       "a result without text must still explain itself")
expect(ClaudeCodeProtocol.decode(line("nope")) == nil, "garbage lines decode to nil")

// ── Arguments ──

expect(ClaudeCodeProtocol.permissionMode(for: .observe) == "plan"
       && ClaudeCodeProtocol.permissionMode(for: .workspace) == "acceptEdits"
       && ClaudeCodeProtocol.permissionMode(for: .unattended) == "bypassPermissions",
       "trust profile → permission mode mapping changed")
expect(ClaudeCodeProtocol.effortFlag("minimal") == "low" && ClaudeCodeProtocol.effortFlag("xhigh") == "xhigh"
       && ClaudeCodeProtocol.effortFlag("") == nil && ClaudeCodeProtocol.effortFlag("bogus") == nil,
       "effort ladder → --effort mapping changed")

let fresh = ClaudeCodeProtocol.arguments(
    resumeSessionID: nil, newSessionID: "11111111-2222-3333-4444-555555555555",
    trustProfile: .workspace, model: "sonnet", reasoningEffort: "high",
    extraDirectories: ["/tmp/tickets", "/tmp/queue"])
expect(fresh.prefix(7) == ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages"],
       "headless stream-json contract changed: \(fresh)")
expect(fresh.contains("--session-id") && fresh.contains("11111111-2222-3333-4444-555555555555") && !fresh.contains("--resume"),
       "a fresh session must be given our own id")
expect(fresh.contains("--strict-mcp-config") && fresh.contains("--setting-sources") && fresh.contains("user"),
       "MCP servers must stay out; the user's global settings apply")
expect(fresh.contains("--model") && fresh.contains("sonnet") && fresh.contains("--effort") && fresh.contains("high"),
       "model and effort must reach the CLI")
expect(fresh.suffix(3) == ["--add-dir", "/tmp/tickets", "/tmp/queue"], "extra roots ride --add-dir last")
expect(!fresh.contains("--dangerously-skip-permissions"), "workspace must not bypass permissions")

let resumed = ClaudeCodeProtocol.arguments(
    resumeSessionID: "abc", newSessionID: "unused", trustProfile: .unattended,
    model: "  ", reasoningEffort: nil, extraDirectories: [])
expect(resumed.contains("--resume") && resumed.contains("abc") && !resumed.contains("--session-id"),
       "a remembered session must be resumed")
expect(resumed.contains("--dangerously-skip-permissions") && resumed.contains("bypassPermissions"),
       "unattended bypasses the CLI's prompts")
expect(!resumed.contains("--model") && !resumed.contains("--effort") && !resumed.contains("--add-dir"),
       "blank model, unset effort, and no roots must send nothing")

// ── The stdin message ──

let message = ClaudeCodeProtocol.userMessage(text: "hi", jpegs: [Data([0xFF, 0xD8])])
expect(message.last == 0x0A, "the message must be newline-terminated")
let object = try! JSONSerialization.jsonObject(with: message.dropLast()) as! [String: Any]
let content = (object["message"] as! [String: Any])["content"] as! [[String: Any]]
expect(object["type"] as? String == "user" && content.count == 2
       && content[0]["text"] as? String == "hi"
       && (content[1]["source"] as? [String: Any])?["media_type"] as? String == "image/jpeg"
       && (content[1]["source"] as? [String: Any])?["data"] as? String == "/9g=",
       "the user message must carry text then base64 JPEG image blocks: \(object)")

expect(ClaudeCodeProtocol.activityLabel(forTool: "Bash") == "Running a command"
       && ClaudeCodeProtocol.activityLabel(forTool: "Edit") == "Editing files"
       && ClaudeCodeProtocol.activityLabel(forTool: "mcp__foo") == "Using mcp__foo",
       "tool → activity labels changed")

let environment = ClaudeCodeAgentRuntime.sanitizedEnvironment(source: [
    "PATH": "/usr/bin", "HOME": "/tmp/home", "ANTHROPIC_API_KEY": "secret",
    "OPENAI_API_KEY": "secret", "CLAUDE_CODE_OAUTH_TOKEN": "secret",
])
expect(environment == ["PATH": "/usr/bin", "HOME": "/tmp/home"],
       "Claude Code child inherited a non-allowlisted environment value")

print("claude code runtime tests passed")
