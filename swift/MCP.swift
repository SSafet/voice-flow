import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  MCP sessions — one per connected Claude Code instance
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Streamable HTTP session management: initialize mints an Mcp-Session-Id
//  the client echoes on every request, so several Claude Code sessions can
//  be told apart — the user picks which one their voice input goes to
//  ("Voice Goes To" in the menu bar; AppDelegate.targetSessionId).

struct MCPSession {
    let id: String
    let number: Int          // display order: "Claude #2"
    let firstSeen: Date
    var lastSeen: Date
    /// Self-chosen via the set_session_name tool ("voice-flow — routing").
    var name: String?
    /// Whether the one-time "name yourself" hint was already appended to a
    /// tool result of this session.
    var nudgedForName = false
    /// False until the session first does something user-facing (report,
    /// ask, listen, overlay). Merely connecting — every Claude Code session
    /// initializes every registered MCP server — earns no picker dot, no
    /// ⌃⌥N slot, and no voice-target eligibility.
    var engaged = false

    var label: String { name ?? "Claude #\(number)" }
}

final class MCPSessionRegistry {
    private var sessions: [String: MCPSession] = [:]
    private var counter = 0
    private let lock = DispatchQueue(label: "voiceflow.mcp-sessions")

    /// Sessions silent this long are treated as gone. Claude Code DELETEs
    /// on a clean exit, but a killed/crashed session never does — without
    /// pruning, a ghost holds a picker slot (and the pill's number dot)
    /// indefinitely. A live-but-idle session that gets pruned self-heals:
    /// its next request is silently re-adopted by touch().
    private let staleAfter: TimeInterval = 2 * 3600

    /// Callers must hold `lock`.
    private func pruneStale() {
        let cutoff = Date().addingTimeInterval(-staleAfter)
        for (id, session) in sessions where session.lastSeen < cutoff {
            sessions.removeValue(forKey: id)
        }
    }

    /// New session for an initialize request.
    func begin() -> MCPSession {
        lock.sync {
            counter += 1
            let session = MCPSession(id: UUID().uuidString, number: counter,
                                     firstSeen: Date(), lastSeen: Date())
            sessions[session.id] = session
            return session
        }
    }

    /// Refresh lastSeen. Unknown ids (a Claude session outliving a Voice
    /// Flow restart) are silently re-adopted rather than rejected.
    func touch(_ id: String?) -> (session: MCPSession?, isNew: Bool) {
        guard let id else { return (nil, false) }
        return lock.sync {
            if var session = sessions[id] {
                session.lastSeen = Date()
                sessions[id] = session
                return (session, false)
            }
            counter += 1
            let session = MCPSession(id: id, number: counter,
                                     firstSeen: Date(), lastSeen: Date())
            sessions[id] = session
            return (session, true)
        }
    }

    func close(_ id: String) -> MCPSession? {
        lock.sync { sessions.removeValue(forKey: id) }
    }

    /// Set the session's display name. Returns the updated session.
    func rename(_ id: String, to name: String) -> MCPSession? {
        lock.sync {
            guard var session = sessions[id] else { return nil }
            session.name = name
            sessions[id] = session
            return session
        }
    }

    /// True exactly once per unnamed session — marks the nudge as spent.
    /// Only engaged sessions are nudged: a session the user never sees
    /// doesn't need a name.
    func consumeNameNudge(_ id: String) -> Bool {
        lock.sync {
            guard var session = sessions[id], session.engaged,
                  session.name == nil, !session.nudgedForName else {
                return false
            }
            session.nudgedForName = true
            sessions[id] = session
            return true
        }
    }

    /// Mark a session engaged (user-visible). Returns true only on the
    /// transition, so the caller can refresh UI exactly once.
    func markEngaged(_ id: String) -> Bool {
        lock.sync {
            guard var session = sessions[id], !session.engaged else { return false }
            session.engaged = true
            sessions[id] = session
            return true
        }
    }

    func session(_ id: String?) -> MCPSession? {
        guard let id else { return nil }
        return lock.sync { sessions[id] }
    }

    var count: Int {
        lock.sync {
            pruneStale()
            return sessions.count
        }
    }

    /// Connection order — stable numbering for the session strip and the
    /// ⌃⌥1–6 switch hotkeys.
    func ordered() -> [MCPSession] {
        lock.sync {
            pruneStale()
            return sessions.values.sorted { $0.number < $1.number }
        }
    }

    /// Most recently active first.
    func list() -> [MCPSession] {
        lock.sync {
            pruneStale()
            return sessions.values.sorted { $0.lastSeen > $1.lastSeen }
        }
    }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  MCP Server — Voice Flow as a peer of Claude Code
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Implements the Model Context Protocol over Streamable HTTP (plain JSON
//  responses, no SSE) at http://127.0.0.1:8792/mcp. Claude Code registers
//  it once:  claude mcp add -s user -t http voice-flow http://127.0.0.1:8792/mcp
//
//  Tool calls arrive on background HTTP threads; handlers may block for a
//  long time (ask_user, wait_for_message), which is exactly the point —
//  the tool result is the user's delayed answer.

final class MCPServer {

    /// The one-time registration command the user runs in Terminal so
    /// Claude Code knows about this server (surfaced in Settings).
    static let registerCommand = "claude mcp add -s user -t http voice-flow http://127.0.0.1:8792/mcp"

    /// All tool calls that arrive WITHOUT an Mcp-Session-Id share this
    /// registry entry, so even a degraded client has a picker dot.
    static let anonymousSessionId = "anonymous"

    /// When a client (Claude Code) last sent any request. Main thread only —
    /// the Settings window reads it to show connection status.
    static private(set) var lastActivity: Date?

    struct ToolResult {
        let text: String
        let isError: Bool
        static func ok(_ text: String) -> ToolResult { ToolResult(text: text, isError: false) }
        static func fail(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
    }

    /// (toolName, arguments, callingSession) → result. Called on a
    /// background thread; may block.
    var callTool: ((String, [String: Any], MCPSession?) -> ToolResult)?

    let sessions = MCPSessionRegistry()
    /// A session appeared (initialize, or an unknown id re-adopted after a
    /// Voice Flow restart). Called on the HTTP thread — hop to main for UI.
    var onSessionConnected: ((MCPSession) -> Void)?

    private let serverInstructions = """
        Voice Flow is a macOS voice + screen companion app the user is running. It is your \
        interaction layer with the user — richer than plain text, in both directions.

        You are INVISIBLE to the user until you first interact (report_to_user, \
        wait_for_message, or an overlay) — merely being connected shows them nothing. Call \
        set_session_name early with a short project/task name ("voice-flow — session \
        routing") so you appear already named when you do interact: several Claude sessions \
        may be connected at once, and the user routes their voice input by that name.

        Talking to the user — report_to_user, the one message tool:
        - Always send substance: summary is the one-liner receipt, details carries what \
        happened, what changed and where, and what they should do. A bare "done" helps nobody.
        - Need an answer? Pass question — it BLOCKS until they respond (voice, voice + \
        screenshot, typing, or a recorded demonstration). The user may be away for hours; \
        prefer a long timeout_seconds over re-asking.
        - Finishing your turn after a report? Their spoken reply cannot reach a stopped \
        session on its own. Start the background listener first (the report_to_user result \
        shows the exact command for your session) — when they talk to you, the background \
        task completes and wakes you with their words.

        Hearing from the user:
        - wait_for_message: listening mode. Talk messages are delivered live ONLY while you \
        are parked here — call it in a loop to be their companion while they read or work \
        (messages may carry a screenshot of what they were looking at); a timeout is normal, \
        call it again. When nobody is listening, talk messages QUEUE for the session the user \
        is pointed at — you get them on your next tool call (results nudge you) or via \
        check_messages, but only a running or background-listening session gets woken.
        - get_latest_capture / list_captures: recorded demonstrations — spoken narration plus \
        ordered screenshots. When the user says they recorded/captured/showed something, fetch it.
        - The ambient workflow watcher (when the user enables it) logs their workday to \
        ~/.config/voice-flow/watcher/<yyyy-mm-dd>/ — activity.jsonl holds one frontmost-app \
        line per 5s tick plus deduped screenshots. Read those files directly to analyze how \
        the user works; the review protocol is ~/.config/voice-flow/watcher/ANALYZE.md.

        Showing the user:
        - Elements you place are scoped to YOUR session: if the user is currently working \
        with another Claude session, yours are NOT drawn over it — the user gets a small \
        notification and sees your elements when they switch to you (⌃⌥1–6). \
        Your tool results tell you which happened.
        - Every on-screen element you place is a LIVE JSON FILE in \
        ~/.config/voice-flow/overlays/ — the screen re-renders within ~0.5s of any file change. \
        The show_guide / update_guide / show_panel / annotate_screen tools write these files for \
        you, but you can equally create or Edit the files directly with your file tools; the \
        schema is documented in ~/.config/voice-flow/overlays/_schema.md. Deleting a file \
        removes the element.
        - Guides: floating step-by-step checklists you advance as the user progresses.
        - Panels: formatted reference info (headings, text, code blocks, bullets) pinned next \
        to their work.
        - Annotations: circles, arrows, labels, rects, lines drawn over the screen, using pixel \
        coordinates from take_screenshot (which also reports the user's cursor position).
        - Audio is on demand: the user plays any of your messages aloud when they choose \
        (re-selecting your session or the speaker icon). There is no way to auto-play sound.

        Screenshots, frames, and overlay files are absolute paths on this machine — read them.
        """

    // ── HTTP entry point ────────────────────────────────

    /// Handle one POST /mcp body. Returns (httpStatus, responseBody,
    /// sessionIdToIssue) — the id is set only for initialize responses and
    /// becomes the Mcp-Session-Id header. A 202 with nil body answers
    /// notifications.
    func handle(body: Data, sessionId: String?) -> (status: Int, payload: Data?, sessionId: String?) {
        DispatchQueue.main.async { Self.lastActivity = Date() }
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return respond(error: (-32700, "Parse error"), id: NSNull())
        }
        guard let method = message["method"] as? String else {
            return respond(error: (-32600, "Invalid request"), id: message["id"] ?? NSNull())
        }
        let id = message["id"]

        // Refresh (or re-adopt) the caller's session on every request. A
        // client calling TOOLS with no session header at all (seen from
        // some Claude Code states after a Voice Flow restart) would
        // otherwise be a black hole — no picker dot, unanswerable asks,
        // nothing for the user to switch to. Fold all such traffic into
        // one well-known "anonymous" session so it stays visible and
        // routable (it names itself via the usual nudge).
        var session: MCPSession?
        if method != "initialize" {
            var effectiveId = sessionId
            if effectiveId == nil, method == "tools/call" {
                effectiveId = Self.anonymousSessionId
            }
            let (touched, isNew) = sessions.touch(effectiveId)
            session = touched
            if isNew, let touched {
                onSessionConnected?(touched)
            }
        }

        // Notifications get no JSON-RPC response.
        guard let id else {
            return (202, nil, nil)
        }

        switch method {
        case "initialize":
            let created = sessions.begin()
            onSessionConnected?(created)
            let params = message["params"] as? [String: Any]
            let requested = params?["protocolVersion"] as? String ?? "2025-06-18"
            let supported = ["2024-11-05", "2025-03-26", "2025-06-18"]
            let version = supported.contains(requested) ? requested : "2025-06-18"
            let (status, payload, _) = respond(result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "voice-flow", "version": "2.0.0"],
                "instructions": serverInstructions,
            ], id: id)
            return (status, payload, created.id)

        case "ping":
            return respond(result: [String: Any](), id: id)

        case "tools/list":
            return respond(result: ["tools": Self.toolDefinitions], id: id)

        case "tools/call":
            guard let params = message["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                return respond(error: (-32602, "tools/call requires params.name"), id: id)
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let callTool else {
                return respond(error: (-32603, "Voice Flow is still starting up."), id: id)
            }
            var result = callTool(name, arguments, session)
            // One-time reminder: an unnamed session is hard for the user
            // to route voice input to.
            if !result.isError, name != "set_session_name",
               let session, sessions.consumeNameNudge(session.id) {
                result = ToolResult.ok(result.text
                    + "\n\n(This session is unnamed — call set_session_name with a short project/task label so the user can tell their Claude sessions apart.)")
            }
            return respond(result: [
                "content": [["type": "text", "text": result.text]],
                "isError": result.isError,
            ], id: id)

        default:
            return respond(error: (-32601, "Method not found: \(method)"), id: id)
        }
    }

    private func respond(result: [String: Any], id: Any) -> (Int, Data?, String?) {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        return (200, try? JSONSerialization.data(withJSONObject: envelope), nil)
    }

    private func respond(error: (code: Int, message: String), id: Any) -> (Int, Data?, String?) {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": error.code, "message": error.message],
        ]
        return (200, try? JSONSerialization.data(withJSONObject: envelope), nil)
    }

    // ── Tool catalog ────────────────────────────────────

    private static let positionProperty: [String: Any] = [
        "type": "string",
        "enum": ["top-left", "top-right", "bottom-left", "bottom-right", "center-left", "center-right", "center"],
        "description": "Screen edge/corner to place it at. Pick the side away from where the user is working. (Overlay files also accept an explicit [x, y] position in screenshot pixels.)",
    ]

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "set_session_name",
            "description": """
            Name this Claude Code session inside Voice Flow — a short project/task label like \
            "voice-flow — session routing". The user can have several Claude sessions connected \
            at once; they route their voice input by this name (unnamed sessions show as \
            "Claude #N"). Call it once right after connecting, and again if your focus changes. \
            Naming is silent: nothing appears on the user's screen, and your session stays \
            invisible to them until your first report_to_user / wait_for_message / overlay call.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Short label, ~40 characters max — repo and current task work well.",
                    ],
                ],
                "required": ["name"],
            ],
        ],
        [
            "name": "report_to_user",
            "description": """
            Tell the user something through Voice Flow — the ONE way to message them. They get \
            a small notification receipt (never the full text; audio only on demand); they read \
            the full report by switching onto your session (⌃⌥N) or in their Messages tab, \
            which keeps it forever. Always send real context, not a headline: `summary` is the \
            one-liner, `details` carries what happened, what changed and where, and what (if \
            anything) they should do. Without `question` this returns immediately — use it for \
            completed work and milestones. With `question` it BLOCKS until they answer (by \
            voice, voice + fresh screenshot, typing, or a recorded demonstration; the result \
            has their words plus absolute screenshot paths — read those files). Use `question` \
            whenever you cannot proceed without their input; the user may be away, so pass a \
            generous timeout_seconds — hours are fine. If they dismiss or the timeout passes \
            you get a non-error explanation; late answers queue in the inbox (check_messages).
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "summary": [
                        "type": "string",
                        "description": "One or two sentences: what happened, or what you need. This is what the user sees first.",
                    ],
                    "details": [
                        "type": "string",
                        "description": "The substance: what was done / found, where (paths, PRs, commands), and what action you need from the user, if any. Markdown-free plain text, a short paragraph or a few lines.",
                    ],
                    "question": [
                        "type": "string",
                        "description": "Ask this and BLOCK until the user answers. Omit for fire-and-forget reports.",
                    ],
                    "timeout_seconds": [
                        "type": "number",
                        "description": "Only with `question`: how long to wait for the answer, in seconds (10–14400). Default 1800. The user may be away from the machine — prefer long timeouts over re-asking.",
                    ],
                ],
                "required": ["summary", "details"],
            ],
        ],
        [
            "name": "check_messages",
            "description": """
            Fetch (and clear) messages queued for you: late answers to a report_to_user \
            question that timed out, and anything the user spoke at your session while you \
            weren't listening. Non-blocking. Messages may include screenshot paths of what \
            they were looking at — read them.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "wait_for_message",
            "description": """
            Block until the user sends a message with their talk hotkeys, or the timeout \
            passes. This is listening mode: call it in a loop to be the user's live companion \
            while they read or work — they press talk anywhere, speak ("explain this part"), \
            optionally with a screenshot attached, and you get it instantly. Returns \
            immediately if messages are already queued. A timeout with NO message is a normal, \
            non-error result — just call wait_for_message again to keep listening. To keep \
            receiving after your turn ends, run this via the background listener instead \
            (report_to_user results show the exact command) so the user's reply wakes you.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "timeout_seconds": [
                        "type": "number",
                        "description": "Max seconds to wait for a message (5–3600). Default 600.",
                    ],
                ],
            ],
        ],
        [
            "name": "get_latest_capture",
            "description": """
            Return the user's most recent Voice Flow capture — a recorded demonstration made of \
            spoken narration plus ordered screenshots of what they were doing. The result has \
            the transcript text and the absolute paths of every frame, in order; read the frames \
            alongside the narration. Use when the user says they recorded, captured, or showed \
            you something in Voice Flow.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "list_captures",
            "description": "List recent Voice Flow captures (recorded demonstrations), newest first, with id, recording time, duration, frame count, and a transcript preview. Follow up with get_latest_capture or read a bundle's transcript.md directly via its directory path.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "Maximum captures to return (1–40). Default 10.",
                    ],
                ],
            ],
        ],
        [
            "name": "take_screenshot",
            "description": "Capture the user's screen right now, save it as a JPEG, and return its absolute file path, pixel dimensions, and the user's current cursor position in the same pixel space. Read the file to see the image. All overlay/annotation coordinates use this image's pixel space.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "show_guide",
            "description": """
            Float a step-by-step guide on the user's screen — use it instead of a long chat \
            answer when walking them through a task in another app. Steps before active_step \
            render as done ✓, the active one is highlighted. Writes a live JSON file \
            (~/.config/voice-flow/overlays/<id>.json) and returns its path — you can also edit \
            that file directly for updates (schema in overlays/_schema.md). Advance progress \
            with update_guide as they work (take screenshots to see where they are); remove \
            with remove_overlay.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Overlay id (file name). Default \"guide\". Use distinct ids to show several guides."],
                    "title": ["type": "string", "description": "Short guide title."],
                    "steps": [
                        "type": "array",
                        "description": "The steps, in order.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string", "description": "One imperative sentence."],
                                "detail": ["type": "string", "description": "Optional sub-text, rendered monospaced — exact commands or values to type."],
                            ],
                            "required": ["text"],
                        ],
                    ],
                    "active_step": [
                        "type": "integer",
                        "description": "1-based index of the step the user should do now. Default 1. Set past the last step to mark everything done.",
                    ],
                    "position": positionProperty,
                    "note": ["type": "string", "description": "Optional highlighted line under the title (warnings, current status)."],
                ],
                "required": ["title", "steps"],
            ],
        ],
        [
            "name": "update_guide",
            "description": "Update a guide already on screen: advance active_step, change the note or title, or replace the steps (e.g. the user's setup differs from what you assumed). Omitted fields keep their current value. Equivalent to editing the guide's JSON file.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Guide overlay id. Default \"guide\"."],
                    "active_step": ["type": "integer", "description": "1-based index of the current step. Set past the last step to mark all done."],
                    "note": ["type": "string", "description": "Replace the highlighted note line. Empty string removes it."],
                    "title": ["type": "string", "description": "Replace the title."],
                    "steps": [
                        "type": "array",
                        "description": "Replace all steps.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "text": ["type": "string"],
                                "detail": ["type": "string"],
                            ],
                            "required": ["text"],
                        ],
                    ],
                    "position": positionProperty,
                ],
            ],
        ],
        [
            "name": "show_panel",
            "description": """
            Float a formatted information panel on the user's screen — richer than a guide: \
            headings, paragraphs, monospaced code blocks, and bullet lists. Use for reference \
            values while they fill a form, commands to copy, or an explanation pinned next to \
            what they're reading. Writes a live JSON file and returns its path — edit the file \
            directly to update the panel in place (it re-renders within ~0.5s). Several panels \
            can be on screen at once under different ids.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Overlay id (file name). Default \"panel\". Use distinct ids for multiple panels."],
                    "title": ["type": "string", "description": "Panel title."],
                    "blocks": [
                        "type": "array",
                        "description": "Content blocks, top to bottom.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "kind": [
                                    "type": "string",
                                    "enum": ["heading", "text", "code", "bullets"],
                                ],
                                "text": ["type": "string", "description": "For heading/text/code."],
                                "items": [
                                    "type": "array", "items": ["type": "string"],
                                    "description": "For bullets.",
                                ],
                            ],
                            "required": ["kind"],
                        ],
                    ],
                    "position": positionProperty,
                    "width": ["type": "number", "description": "Panel width in screenshot pixels (240–620). Default ~340."],
                    "note": ["type": "string", "description": "Optional highlighted line under the title."],
                ],
                "required": ["blocks"],
            ],
        ],
        [
            "name": "annotate_screen",
            "description": """
            Draw directly on the user's screen: circles, arrows, labels, rectangles, and lines \
            on a click-through overlay. Coordinates are pixels in the most recent \
            take_screenshot image — call take_screenshot first (it also gives you the cursor \
            position, useful when the user says "this thing here"). The shapes live in a JSON \
            overlay file (returned path) that you can edit directly; they stay visible and \
            appear in later screenshots until cleared.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "actions": [
                        "type": "array",
                        "description": "Shapes to draw, in order.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "type": [
                                    "type": "string",
                                    "enum": ["circle", "arrow", "label", "rect", "line"],
                                ],
                                "center": [
                                    "type": "array", "items": ["type": "number"],
                                    "description": "circle: [x, y] center.",
                                ],
                                "radius": ["type": "number", "description": "circle: radius in px. Default 60."],
                                "from": [
                                    "type": "array", "items": ["type": "number"],
                                    "description": "arrow/line: [x, y] start.",
                                ],
                                "to": [
                                    "type": "array", "items": ["type": "number"],
                                    "description": "arrow/line: [x, y] end (arrow tip points here).",
                                ],
                                "rect": [
                                    "type": "array", "items": ["type": "number"],
                                    "description": "rect: [x, y, width, height].",
                                ],
                                "position": [
                                    "type": "array", "items": ["type": "number"],
                                    "description": "label: [x, y] top-left of the text.",
                                ],
                                "text": ["type": "string", "description": "label: the text. Keep it short."],
                                "size": ["type": "number", "description": "label: font size (12–48). Default 22."],
                                "color": [
                                    "type": "string",
                                    "enum": ["red", "amber", "blue", "green", "white"],
                                    "description": "Default red.",
                                ],
                            ],
                            "required": ["type"],
                        ],
                    ],
                    "clear_first": ["type": "boolean", "description": "Replace this overlay's existing shapes instead of adding to them. Default false."],
                    "id": ["type": "string", "description": "Annotation overlay id. Default \"annotations\"."],
                ],
                "required": ["actions"],
            ],
        ],
        [
            "name": "clear_annotations",
            "description": "Erase everything drawn on the user's screen: removes all annotation overlay files and clears the user's own pen/text marks.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "remove_overlay",
            "description": "Remove an on-screen overlay (guide, panel, or annotations) by deleting its file. Pass id \"all\" to clear every overlay from the screen.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The overlay id, or \"all\"."],
                ],
                "required": ["id"],
            ],
        ],
        [
            "name": "list_overlays",
            "description": "List the overlays currently defined (guides, panels, annotations) with their ids, types, visibility, and file paths. Edit those files directly to update what's on screen — the schema is documented in ~/.config/voice-flow/overlays/_schema.md.",
            "inputSchema": [
                "type": "object",
                "properties": [String: Any](),
            ],
        ],
        [
            "name": "get_recent_dictations",
            "description": "Return the user's recent Voice Flow dictations (text they dictated into other apps), newest first. Useful when they refer to \"what I just dictated\".",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "description": "Maximum entries to return (1–50). Default 10.",
                    ],
                ],
            ],
        ],
    ]
}
