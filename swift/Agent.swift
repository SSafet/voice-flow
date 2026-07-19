import Foundation
import Cocoa
import CoreGraphics

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Agent (OpenRouter / OpenAI-compatible client + tool loop)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let DefaultAgentBaseURL = "https://openrouter.ai/api/v1"
let DefaultAgentModel = "anthropic/claude-sonnet-4.5"
private let AgentMaxTokens = 8_192

enum AgentActivity: String {
    case idle, thinking, responding, acting
}

enum AgentError: LocalizedError {
    case missingAPIKey
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No agent API key. Add your OpenRouter key in Settings."
        case .requestFailed(let message):
            return message
        }
    }
}

// ── Agent Session ───────────────────────────────────────
// Owns the conversation and runs the tool loop.

final class AgentSession {
    var onActivityChanged: ((AgentActivity) -> Void)?
    var onAssistantStart: (() -> Void)?
    var onAssistantDelta: ((String) -> Void)?
    var onAssistantDone: ((String) -> Void)?
    var onToolActivity: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onHistoryChanged: (() -> Void)?

    /// When false, the computer tool only allows screenshots.
    var allowControl = false

    private(set) var isRunning = false
    private var messages: [[String: Any]] = []
    private var interruptRequested = false
    private var activeTask: Task<Void, Never>?
    private var runningSessionId: String?

    private let screenCapture: ScreenCapture
    private let control = ComputerControl()
    private let history: AssistantHistoryStore
    private(set) var currentSessionId: String

    // Codex subscription backend: the CLI keeps the conversation server-side,
    // we hold the thread id; `messages` still accumulates so the API path can
    // take over mid-conversation on fallback.
    private let codex = CodexExecBackend()
    private var codexThreadId: String?
    private var pendingCodexTurn: (text: String, images: [Data])?

    // Screenshot geometry: everything sent to the model uses one fixed size
    // so computer-tool coordinates stay consistent across the session.
    private var imageWidth = 0
    private var imageHeight = 0

    private(set) var activity: AgentActivity = .idle {
        didSet {
            let value = activity
            DispatchQueue.main.async { self.onActivityChanged?(value) }
        }
    }

    init(screenCapture: ScreenCapture, history: AssistantHistoryStore = AssistantHistoryStore()) {
        self.screenCapture = screenCapture
        self.history = history
        currentSessionId = history.activeSessionId
        loadRuntime(from: history.activeConversation())
        recomputeGeometry()
    }

    @discardableResult
    func reset() -> AssistantConversation {
        interrupt()
        return createConversation()
    }

    var hasConversation: Bool { !history.activeConversation().messages.isEmpty }
    var currentConversation: AssistantConversation { history.activeConversation() }
    var conversations: [AssistantConversation] { history.conversations() }

    @discardableResult
    func createConversation() -> AssistantConversation {
        let conversation = history.createConversation()
        currentSessionId = conversation.id
        loadRuntime(from: conversation)
        notifyHistoryChanged()
        return conversation
    }

    @discardableResult
    func activateConversation(_ id: String) -> AssistantConversation? {
        guard !isRunning, let conversation = history.activate(id) else { return nil }
        currentSessionId = conversation.id
        loadRuntime(from: conversation)
        notifyHistoryChanged()
        return conversation
    }

    @discardableResult
    func deleteConversation(_ id: String) -> AssistantConversation? {
        guard !isRunning else { return nil }
        let active = history.delete(id)
        currentSessionId = active.id
        loadRuntime(from: active)
        notifyHistoryChanged()
        return active
    }

    func interrupt() {
        interruptRequested = true
        codex.interrupt()
        activeTask?.cancel()
    }

    private func loadRuntime(from conversation: AssistantConversation) {
        messages = conversation.messages.compactMap { message in
            switch message.role {
            case .note:
                return nil
            case .assistant:
                return ["role": "assistant", "content": message.text]
            case .user:
                var display = message.text
                if let attachment = message.attachmentNote, !attachment.isEmpty {
                    display = display.isEmpty ? attachment : "\(display)\n\(attachment)"
                }
                return ["role": "user", "content": [["type": "text", "text": display]]]
            }
        }
        codexThreadId = conversation.codexThreadId
        pendingCodexTurn = nil
    }

    private func notifyHistoryChanged() {
        DispatchQueue.main.async { self.onHistoryChanged?() }
    }

    private func recomputeGeometry() {
        let screen = NSScreen.screens.first ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = min(1.0, 1440.0 / frame.width)
        imageWidth = Int((frame.width * scale).rounded())
        imageHeight = Int((frame.height * scale).rounded())
        control.imageToScreenScale = frame.width / CGFloat(imageWidth)
    }

    private var systemPrompt: String {
        """
        You are the Voice Flow companion — an assistant that lives in a small floating panel on the user's Mac and works alongside them.

        What you receive:
        - Screenshots of the user's screen, \(imageWidth)x\(imageHeight) pixels. The user can draw and type annotations directly on their screen (arrows, circles, notes); treat those marks as part of what they're telling you.
        - Transcribed voice notes and typed messages.

        How to respond:
        - Your replies appear in a compact chat panel, so be concise and direct. A few short sentences beat a structured report. Plain text only — no markdown headings or tables.
        - If something on screen is ambiguous, say what you see and ask one focused question.
        - You have a `computer` tool for looking at and controlling the user's Mac. All coordinates are pixels in the \(imageWidth)x\(imageHeight) screenshot space, origin at the top-left.
        - When the user asks you to do something on their computer and control is enabled, act in small steps: take a screenshot to orient yourself, act, then take another screenshot to verify. Stop as soon as the request is fulfilled and summarize what you did in one or two sentences.
        - If the computer tool reports that control is disabled, don't retry — briefly tell the user what you would do and that they can enable control from the panel.
        - Never take destructive or irreversible actions (deleting data, sending messages or emails, completing purchases) unless the user explicitly asked for that exact action.
        """
    }

    private var computerToolDefinition: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "computer",
                "description": """
                Look at and control the user's Mac. Actions: `screenshot` (returns a fresh image of the screen), \
                `left_click`, `right_click`, `middle_click`, `double_click`, `triple_click` (need `coordinate`), \
                `left_click_drag` (needs `start_coordinate` and `coordinate`), `mouse_move` (needs `coordinate`), \
                `type` (types `text` into the focused element), `key` (presses a key combo given in `text`, e.g. "cmd+s", "return", "escape"), \
                `scroll` (needs `coordinate`, `scroll_direction`, `scroll_amount`), `wait` (pauses `duration` seconds), `cursor_position`. \
                Coordinates are [x, y] pixels in the screenshot space.
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": [
                                "screenshot", "left_click", "right_click", "middle_click",
                                "double_click", "triple_click", "left_click_drag", "mouse_move",
                                "type", "key", "scroll", "wait", "cursor_position",
                            ],
                        ],
                        "coordinate": [
                            "type": "array",
                            "items": ["type": "integer"],
                            "description": "[x, y] target position in screenshot pixels",
                        ],
                        "start_coordinate": [
                            "type": "array",
                            "items": ["type": "integer"],
                            "description": "[x, y] drag start position",
                        ],
                        "text": ["type": "string", "description": "Text to type, or key combo for `key`"],
                        "duration": ["type": "number", "description": "Seconds for `wait`"],
                        "scroll_direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                        "scroll_amount": ["type": "integer", "description": "Scroll ticks (1-30)"],
                    ],
                    "required": ["action"],
                ],
            ],
        ]
    }

    /// Send a user turn (text and/or screenshots) and run the agent loop.
    func send(text: String?, screenshots: [Data]) {
        guard !isRunning else {
            onError?("The agent is still working — stop it first or wait.")
            return
        }
        let usingCodex = UserSettings.shared.agentBackend == AgentBackendCodex
        // Codex needs no key; problems there surface (or fall back) per turn.
        guard usingCodex || KeychainStore.shared.loadAgentAPIKey() != nil else {
            let message = AgentError.missingAPIKey.localizedDescription
            history.appendMessage(sessionId: currentSessionId, role: .note, text: message)
            notifyHistoryChanged()
            onError?(message)
            return
        }

        recomputeGeometry()
        interruptRequested = false
        isRunning = true

        var content: [[String: Any]] = []
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            content.append(["type": "text", "text": trimmed])
        } else if !screenshots.isEmpty {
            content.append(["type": "text", "text": "(No note — the screenshots are the message.)"])
        }
        for shot in screenshots {
            if let block = imageBlock(from: shot) {
                content.append(block)
            }
        }
        guard !content.isEmpty else {
            isRunning = false
            return
        }
        let sessionId = currentSessionId
        runningSessionId = sessionId
        let promptText = trimmed.isEmpty ? "(No note — the screenshots are the message.)" : trimmed
        history.appendMessage(
            sessionId: sessionId,
            role: .user,
            text: trimmed,
            attachmentNote: Self.attachmentNote(count: screenshots.count))
        history.setTurnState(.running, for: sessionId)
        notifyHistoryChanged()
        messages.append(["role": "user", "content": content])
        pruneOldImages()

        if usingCodex {
            let jpegs = screenshots.compactMap { ImageUtils.resizeExact($0, width: imageWidth, height: imageHeight) }
            pendingCodexTurn = (
                text: promptText,
                images: jpegs
            )
        }

        activeTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func finish(_ finalText: String?) {
        let sessionId = runningSessionId
        runningSessionId = nil
        isRunning = false
        activeTask = nil
        activity = .idle
        if let sessionId {
            if let finalText, !finalText.isEmpty {
                history.appendMessage(sessionId: sessionId, role: .assistant, text: finalText)
            }
            history.setTurnState(.idle, for: sessionId)
            notifyHistoryChanged()
        }
        if let finalText, !finalText.isEmpty {
            DispatchQueue.main.async { self.onAssistantDone?(finalText) }
        }
    }

    private static func attachmentNote(count: Int) -> String? {
        switch count {
        case 0: return nil
        case 1: return "📎 1 screenshot"
        default: return "📎 \(count) screenshots"
        }
    }

    private func runLoop() async {
        if UserSettings.shared.agentBackend == AgentBackendCodex {
            let fallBackToAPI = await runCodexTurn()
            guard fallBackToAPI else { return }
            // `messages` already holds the whole conversation, including this
            // user turn — the API loop below continues it seamlessly.
        }

        var turns = 0
        let maxTurns = 40  // hard stop for runaway tool loops

        while turns < maxTurns {
            turns += 1
            activity = .thinking

            let result: StreamResult
            do {
                result = try await streamOnce()
            } catch is CancellationError {
                handleInterruption()
                return
            } catch {
                if interruptRequested {
                    handleInterruption()
                    return
                }
                let message = error.localizedDescription
                recordNote(message)
                DispatchQueue.main.async { self.onError?(message) }
                finish(nil)
                return
            }

            // Rebuild the assistant message for history
            var assistantMessage: [String: Any] = ["role": "assistant"]
            assistantMessage["content"] = result.text.isEmpty ? NSNull() : result.text
            if !result.toolCalls.isEmpty {
                assistantMessage["tool_calls"] = result.toolCalls.map { call in
                    [
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.name, "arguments": call.arguments],
                    ] as [String: Any]
                }
            }
            messages.append(assistantMessage)

            if result.toolCalls.isEmpty {
                finish(result.text)
                return
            }

            // Execute requested tools
            activity = .acting
            var screenshotImages: [[String: Any]] = []
            for call in result.toolCalls {
                if interruptRequested {
                    messages.append(toolMessage(call.id, "The user interrupted — stop and wait for their next message."))
                    continue
                }
                let (text, image) = await executeTool(call)
                messages.append(toolMessage(call.id, text))
                if let image { screenshotImages.append(image) }
            }
            if !screenshotImages.isEmpty {
                // OpenAI-compatible tool messages are text-only; attach the
                // actual pixels as a follow-up user message.
                var content: [[String: Any]] = [["type": "text", "text": "[Screenshot from the computer tool]"]]
                content.append(contentsOf: screenshotImages)
                messages.append(["role": "user", "content": content])
            }
            pruneOldImages()

            if interruptRequested {
                DispatchQueue.main.async { self.onToolActivity?("Stopped") }
                finish(nil)
                return
            }
        }

        recordNote("Stopped — too many steps in one request.")
        DispatchQueue.main.async { self.onError?("Stopped — too many steps in one request.") }
        finish(nil)
    }

    // ── Codex turn ──────────────────────────────────────

    /// The persona preamble Codex gets on a thread's first turn; later turns
    /// resume the same thread, so it isn't repeated.
    private var codexPreamble: String {
        """
        You are the assistant inside Voice Flow, a macOS companion app for voice dictation, text-to-speech, \
        and screen capture. The user's words arrive from the app's chat panel, and the plain text you reply \
        with is shown directly back in that panel — that IS the communication channel, already connected. \
        Never use tools, commands, or servers to reach, notify, or "connect to" the user; just answer. \
        Only run shell commands when the user's request itself needs local information (files, processes, \
        git state). The user talks by voice or types; screenshots of their screen may be attached — treat \
        any drawn annotations on them as part of the message. Keep replies concise and plain text, no \
        markdown headings or tables. If something on screen is ambiguous, say what you see and ask one \
        focused question.

        Voice Flow keeps its data under ~/.config/voice-flow/, and your sandbox lets you read it:
        - dictations.json — the user's dictation history, newest first; entries are {text, time, destination} \
        (time is time-of-day only). "My transcripts" or "my dictations" means this file.
        - captures/<id>/transcript.md — recorded demonstration sessions: spoken narration plus ordered \
        screenshot frames (in frames/ beside it); meta.json has timing. Newest <id> sorts last.
        - messages.json — messages assistant sessions have pushed to the user (time, session, text).
        When the user says to read, summarize, or work from their transcripts or recordings, read these \
        files directly. Your sandbox is read-only with no network — when asked to create tickets, notes, \
        or other artifacts from them, write the finished content into your reply instead of trying to \
        create files or call external services.
        """
    }

    /// Runs one turn through the Codex CLI. Returns true when the turn should
    /// be retried through the API path instead (Codex failed and a key exists).
    private func runCodexTurn() async -> Bool {
        activity = .thinking
        let turn = pendingCodexTurn ?? (text: "", images: [])
        pendingCodexTurn = nil
        let prompt = (codexThreadId == nil ? codexPreamble + "\n\n" : "") + turn.text
        let sessionId = runningSessionId ?? currentSessionId

        do {
            var started = false
            let result = try await codex.run(
                prompt: prompt,
                images: turn.images,
                resumeThread: codexThreadId,
                onThreadStarted: { [weak self] id in
                    guard let self else { return }
                    // Persist from the parser queue immediately. If Voice Flow
                    // is restarted mid-turn, the next launch can still resume.
                    self.history.setCodexThreadId(id, for: sessionId)
                    self.notifyHistoryChanged()
                },
                onToolActivity: { [weak self] label in
                    DispatchQueue.main.async { self?.onToolActivity?(label) }
                },
                onAgentText: { [weak self] piece in
                    guard let self else { return }
                    if !started {
                        started = true
                        self.activity = .responding
                        DispatchQueue.main.async { self.onAssistantStart?() }
                    }
                    DispatchQueue.main.async { self.onAssistantDelta?(piece) }
                }
            )
            codexThreadId = result.threadId ?? codexThreadId
            if let threadId = codexThreadId {
                history.setCodexThreadId(threadId, for: sessionId)
            }
            messages.append(["role": "assistant", "content": result.text])
            finish(result.text)
            return false
        } catch is CancellationError {
            handleInterruption()
            return false
        } catch {
            if interruptRequested {
                handleInterruption()
                return false
            }
            if KeychainStore.shared.loadAgentAPIKey() != nil {
                vflog("codex turn failed, falling back to API: \(error.localizedDescription)")
                DispatchQueue.main.async { self.onToolActivity?("Codex unavailable — using the API key") }
                return true
            }
            let message = error.localizedDescription
            recordNote(message)
            DispatchQueue.main.async { self.onError?(message) }
            finish(nil)
            return false
        }
    }

    private func handleInterruption() {
        // Keep history valid: answer any dangling tool calls.
        if let last = messages.last,
           (last["role"] as? String) == "assistant",
           let calls = last["tool_calls"] as? [[String: Any]] {
            for call in calls {
                let id = call["id"] as? String ?? ""
                messages.append(toolMessage(id, "The user interrupted — stop and wait for their next message."))
            }
        }
        recordNote("Stopped by the user.")
        DispatchQueue.main.async { self.onToolActivity?("Stopped") }
        finish(nil)
    }

    private func recordNote(_ text: String) {
        history.appendMessage(sessionId: runningSessionId ?? currentSessionId,
                              role: .note, text: text)
        notifyHistoryChanged()
    }

    private func toolMessage(_ callId: String, _ text: String) -> [String: Any] {
        ["role": "tool", "tool_call_id": callId, "content": text]
    }

    // ── Request / streaming ─────────────────────────────

    private struct ToolCall {
        var id: String
        var name: String
        var arguments: String
    }

    private struct StreamResult {
        let text: String
        let toolCalls: [ToolCall]
    }

    private func requestBody() -> [String: Any] {
        var payload: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        payload.append(contentsOf: messages)
        return [
            "model": UserSettings.shared.agentModel,
            "max_tokens": AgentMaxTokens,
            "stream": true,
            "tools": [computerToolDefinition],
            "messages": payload,
        ]
    }

    private func streamOnce() async throws -> StreamResult {
        guard let apiKey = KeychainStore.shared.loadAgentAPIKey() else {
            throw AgentError.missingAPIKey
        }

        let base = UserSettings.shared.agentBaseURL
        guard let url = URL(string: base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions") else {
            throw AgentError.requestFailed("Invalid agent API base URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("https://voiceflow.local", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Voice Flow", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody())

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AgentError.requestFailed("Invalid response from the agent API.")
        }
        if http.statusCode != 200 {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 65_536 { break }
            }
            throw AgentError.requestFailed(apiErrorMessage(status: http.statusCode, body: body))
        }

        var text = ""
        var toolCalls: [Int: ToolCall] = [:]
        var startedResponding = false

        for try await line in bytes.lines {
            if interruptRequested { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let error = event["error"] as? [String: Any] {
                throw AgentError.requestFailed(error["message"] as? String ?? "Unknown streaming error")
            }
            guard let choices = event["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let delta = first["delta"] as? [String: Any] else { continue }

            if let piece = delta["content"] as? String, !piece.isEmpty {
                text += piece
                if !startedResponding {
                    startedResponding = true
                    activity = .responding
                    DispatchQueue.main.async { self.onAssistantStart?() }
                }
                DispatchQueue.main.async { self.onAssistantDelta?(piece) }
            }

            if let calls = delta["tool_calls"] as? [[String: Any]] {
                for chunk in calls {
                    let index = chunk["index"] as? Int ?? 0
                    var call = toolCalls[index] ?? ToolCall(id: "", name: "", arguments: "")
                    if let id = chunk["id"] as? String, !id.isEmpty { call.id = id }
                    if let function = chunk["function"] as? [String: Any] {
                        if let name = function["name"] as? String, !name.isEmpty { call.name = name }
                        if let args = function["arguments"] as? String { call.arguments += args }
                    }
                    toolCalls[index] = call
                }
            }
        }

        let ordered = toolCalls.keys.sorted().compactMap { toolCalls[$0] }
        return StreamResult(text: text, toolCalls: ordered)
    }

    private func apiErrorMessage(status: Int, body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = json["message"] as? String {
                return message
            }
        }
        switch status {
        case 401: return "The agent API key was rejected. Check it in Settings."
        case 402: return "OpenRouter reports insufficient credits."
        case 429: return "Rate limited by the agent API — try again in a moment."
        default: return "Agent API request failed (\(status))."
        }
    }

    // ── Tool execution ──────────────────────────────────

    /// Returns the text result plus an optional image block (screenshots).
    private func executeTool(_ call: ToolCall) async -> (String, [String: Any]?) {
        guard call.name == "computer" else {
            return ("Unknown tool: \(call.name)", nil)
        }
        let input = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
        let action = input["action"] as? String ?? ""

        DispatchQueue.main.async { self.onToolActivity?(Self.describeAction(action, input: input)) }

        let controlActions: Set<String> = [
            "left_click", "right_click", "middle_click", "double_click", "triple_click",
            "left_click_drag", "type", "key", "scroll", "mouse_move",
        ]
        if controlActions.contains(action) && !allowControl {
            return ("Computer control is disabled. The user can enable it with the hand toggle in the Voice Flow panel.", nil)
        }

        switch action {
        case "screenshot":
            if let block = await captureForAgent() {
                return ("Screenshot captured — attached as the next image.", block)
            }
            return ("Screenshot failed — screen recording permission may be missing.", nil)

        case "cursor_position":
            let location = control.cursorPositionInImageSpace()
            return ("X=\(Int(location.x)), Y=\(Int(location.y))", nil)

        case "wait":
            let seconds = min((input["duration"] as? Double) ?? 1.0, 5.0)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ("Waited \(String(format: "%.1f", seconds))s.", nil)

        case "mouse_move":
            guard let point = coordinate(from: input) else { return ("Missing coordinate.", nil) }
            control.move(to: point)
            return ("Moved cursor.", nil)

        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            guard let point = coordinate(from: input) else { return ("Missing coordinate.", nil) }
            control.click(action: action, at: point, modifiers: input["modifiers"] as? String)
            return ("Clicked.", nil)

        case "left_click_drag":
            guard let start = coordinate(from: input, key: "start_coordinate"),
                  let end = coordinate(from: input) else {
                return ("Missing coordinates for drag.", nil)
            }
            control.drag(from: start, to: end)
            return ("Dragged.", nil)

        case "type":
            let text = input["text"] as? String ?? ""
            control.typeText(text)
            return ("Typed \(text.count) characters.", nil)

        case "key":
            let combo = input["text"] as? String ?? ""
            if control.pressKeyCombo(combo) {
                return ("Pressed \(combo).", nil)
            }
            return ("Unknown key combination: \(combo)", nil)

        case "scroll":
            guard let point = coordinate(from: input) else { return ("Missing coordinate.", nil) }
            let direction = input["scroll_direction"] as? String ?? "down"
            let amount = input["scroll_amount"] as? Int ?? 3
            control.scroll(at: point, direction: direction, amount: amount)
            return ("Scrolled \(direction).", nil)

        default:
            return ("Unsupported action: \(action)", nil)
        }
    }

    private func coordinate(from input: [String: Any], key: String = "coordinate") -> CGPoint? {
        guard let pair = input[key] as? [Any], pair.count == 2 else { return nil }
        let x = (pair[0] as? Double) ?? Double(pair[0] as? Int ?? -1)
        let y = (pair[1] as? Double) ?? Double(pair[1] as? Int ?? -1)
        guard x >= 0, y >= 0 else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func describeAction(_ action: String, input: [String: Any]) -> String {
        switch action {
        case "screenshot": return "Looking at the screen"
        case "type": return "Typing…"
        case "key": return "Pressing \(input["text"] as? String ?? "keys")"
        case "scroll": return "Scrolling"
        case "wait": return "Waiting"
        case "left_click", "double_click", "triple_click", "right_click", "middle_click": return "Clicking"
        case "left_click_drag": return "Dragging"
        case "mouse_move": return "Moving the cursor"
        case "cursor_position": return "Checking the cursor"
        default: return "Working…"
        }
    }

    // ── Screenshots for the model ───────────────────────

    func captureForAgent() async -> [String: Any]? {
        guard let raw = try? await screenCapture.captureScreen() else { return nil }
        return imageBlock(from: raw)
    }

    private func imageBlock(from raw: Data) -> [String: Any]? {
        guard let jpeg = ImageUtils.resizeExact(raw, width: imageWidth, height: imageHeight) else { return nil }
        return [
            "type": "image_url",
            "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
        ]
    }

    /// Keep only the most recent screenshots in history — old frames burn
    /// context without adding much. Replaced with a short text marker.
    /// 8 accommodates a full session bundle (buffered frames + final shot).
    private func pruneOldImages(keep: Int = 8) {
        var seen = 0
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            guard (messages[index]["role"] as? String) == "user",
                  var content = messages[index]["content"] as? [[String: Any]] else { continue }
            var changed = false
            for blockIndex in stride(from: content.count - 1, through: 0, by: -1) {
                if (content[blockIndex]["type"] as? String) == "image_url" {
                    seen += 1
                    if seen > keep {
                        content[blockIndex] = ["type": "text", "text": "[earlier screenshot removed]"]
                        changed = true
                    }
                }
            }
            if changed {
                messages[index]["content"] = content
            }
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Computer Control (CGEvent mouse + keyboard synthesis)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

final class ComputerControl {
    /// Multiply model (image) coordinates by this to get screen points.
    var imageToScreenScale: CGFloat = 1.0

    private func screenPoint(_ imagePoint: CGPoint) -> CGPoint {
        CGPoint(x: imagePoint.x * imageToScreenScale, y: imagePoint.y * imageToScreenScale)
    }

    func cursorPositionInImageSpace() -> CGPoint {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard imageToScreenScale > 0 else { return location }
        return CGPoint(x: location.x / imageToScreenScale, y: location.y / imageToScreenScale)
    }

    func move(to imagePoint: CGPoint) {
        let point = screenPoint(imagePoint)
        post(CGEvent(mouseEventSource: source(), mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    }

    func click(action: String, at imagePoint: CGPoint, modifiers: String?) {
        let point = screenPoint(imagePoint)
        let flags = modifierFlags(from: modifiers)

        let (button, down, up): (CGMouseButton, CGEventType, CGEventType)
        switch action {
        case "right_click": (button, down, up) = (.right, .rightMouseDown, .rightMouseUp)
        case "middle_click": (button, down, up) = (.center, .otherMouseDown, .otherMouseUp)
        default: (button, down, up) = (.left, .leftMouseDown, .leftMouseUp)
        }

        let clicks: Int64
        switch action {
        case "double_click": clicks = 2
        case "triple_click": clicks = 3
        default: clicks = 1
        }

        move(to: imagePoint)
        usleep(60_000)
        for clickState in 1...clicks {
            let downEvent = CGEvent(mouseEventSource: source(), mouseType: down, mouseCursorPosition: point, mouseButton: button)
            let upEvent = CGEvent(mouseEventSource: source(), mouseType: up, mouseCursorPosition: point, mouseButton: button)
            downEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
            upEvent?.setIntegerValueField(.mouseEventClickState, value: clickState)
            if let flags { downEvent?.flags = flags; upEvent?.flags = flags }
            post(downEvent)
            usleep(30_000)
            post(upEvent)
            usleep(60_000)
        }
    }

    func drag(from startImage: CGPoint, to endImage: CGPoint) {
        let start = screenPoint(startImage)
        let end = screenPoint(endImage)
        post(CGEvent(mouseEventSource: source(), mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left))
        usleep(80_000)
        post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left))
        usleep(80_000)

        let steps = 12
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
            usleep(15_000)
        }
        post(CGEvent(mouseEventSource: source(), mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
    }

    func scroll(at imagePoint: CGPoint, direction: String, amount: Int) {
        move(to: imagePoint)
        usleep(40_000)
        let lines = Int32(max(1, min(amount, 30)))
        var vertical: Int32 = 0
        var horizontal: Int32 = 0
        switch direction {
        case "up": vertical = lines
        case "down": vertical = -lines
        case "left": horizontal = lines
        case "right": horizontal = -lines
        default: vertical = -lines
        }
        let event = CGEvent(
            scrollWheelEvent2Source: source(),
            units: .line,
            wheelCount: 2,
            wheel1: vertical,
            wheel2: horizontal,
            wheel3: 0
        )
        post(event)
    }

    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        // Post unicode strings in small chunks — reliable across layouts.
        let characters = Array(text.utf16)
        var index = 0
        while index < characters.count {
            let chunk = Array(characters[index..<min(index + 16, characters.count)])
            let down = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(down)
            let up = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(up)
            usleep(25_000)
            index += 16
        }
    }

    @discardableResult
    func pressKeyCombo(_ combo: String) -> Bool {
        guard let (keyCode, flags) = parseCombo(combo) else { return false }
        let down = CGEvent(keyboardEventSource: source(), virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source(), virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        post(down)
        usleep(30_000)
        post(up)
        return true
    }

    // ── Internals ───────────────────────────────────────

    private func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }

    private func modifierFlags(from text: String?) -> CGEventFlags? {
        guard let text, !text.isEmpty else { return nil }
        var flags = CGEventFlags()
        for part in text.lowercased().split(separator: "+") {
            if let flag = Self.modifierMap[String(part)] {
                flags.insert(flag)
            }
        }
        return flags.isEmpty ? nil : flags
    }

    private func parseCombo(_ combo: String) -> (CGKeyCode, CGEventFlags)? {
        let parts = combo
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }

        var flags = CGEventFlags()
        var baseKey: String?
        for part in parts {
            if let flag = Self.modifierMap[part] {
                flags.insert(flag)
            } else {
                baseKey = part
            }
        }

        // Modifier-only combo (e.g. "cmd") — press the modifier key itself
        if baseKey == nil, parts.count == 1, let modifierKey = Self.modifierKeyCodes[parts[0]] {
            return (modifierKey, [])
        }
        guard let key = baseKey, let keyCode = Self.keyMap[key] else { return nil }
        return (keyCode, flags)
    }

    private static let modifierMap: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand, "meta": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "shift": .maskShift,
        "fn": .maskSecondaryFn, "function": .maskSecondaryFn,
    ]

    private static let modifierKeyCodes: [String: CGKeyCode] = [
        "cmd": 55, "command": 55, "ctrl": 59, "control": 59,
        "alt": 58, "option": 58, "shift": 56, "fn": 63,
    ]

    private static let keyMap: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "equal": 24, "9": 25, "7": 26, "-": 27, "minus": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "comma": 43, "/": 44, "slash": 44, "n": 45, "m": 46,
        ".": 47, "period": 47, "`": 50, "grave": 50,
        "return": 36, "enter": 36, "kp_enter": 76,
        "tab": 48, "space": 49, "spacebar": 49,
        "delete": 51, "backspace": 51, "forward_delete": 117,
        "escape": 53, "esc": 53,
        "home": 115, "end": 119,
        "page_up": 116, "pageup": 116, "pgup": 116,
        "page_down": 121, "pagedown": 121, "pgdn": 121,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    ]
}
