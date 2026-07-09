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

    var label: String { name ?? "Claude #\(number)" }
}

final class MCPSessionRegistry {
    private var sessions: [String: MCPSession] = [:]
    private var counter = 0
    private let lock = DispatchQueue(label: "voiceflow.mcp-sessions")

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
    func consumeNameNudge(_ id: String) -> Bool {
        lock.sync {
            guard var session = sessions[id], session.name == nil, !session.nudgedForName else {
                return false
            }
            session.nudgedForName = true
            sessions[id] = session
            return true
        }
    }

    func session(_ id: String?) -> MCPSession? {
        guard let id else { return nil }
        return lock.sync { sessions[id] }
    }

    var count: Int { lock.sync { sessions.count } }

    /// Most recently active first; sessions silent for a day are dropped
    /// (Claude Code usually DELETEs on exit, but not always).
    func list() -> [MCPSession] {
        lock.sync {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for (id, session) in sessions where session.lastSeen < cutoff {
                sessions.removeValue(forKey: id)
            }
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

        First, introduce yourself: call set_session_name with a short project/task name \
        ("voice-flow — session routing"). The user may have several Claude sessions connected \
        at once and picks which one their voice goes to by that name.

        Hearing from the user:
        - ask_user: put a prompt on their screen and BLOCK until they answer (voice, voice + \
        screenshot, typing, or a recorded demonstration). Use when you can't proceed without them.
        - notify_user + check_messages / wait_for_message: the asynchronous alternative. Talk \
        messages reach you ONLY while you are parked in wait_for_message — call it in a loop \
        to be their live companion while they read or work (each message may carry a \
        screenshot of what they were looking at); a timeout is normal, call it again. When \
        nothing is listening, the user's message is copied to their clipboard for manual \
        pasting instead. Deferred or late answers to your ask_user prompts DO queue — fetch \
        those with check_messages.
        - get_latest_capture / list_captures: recorded demonstrations — spoken narration plus \
        ordered screenshots. When the user says they recorded/captured/showed something, fetch it.
        - The ambient workflow watcher (when the user enables it) logs their workday to \
        ~/.config/voice-flow/watcher/<yyyy-mm-dd>/ — activity.jsonl holds one frontmost-app \
        line per 5s tick plus deduped screenshots. Read those files directly to analyze how \
        the user works; the review protocol is ~/.config/voice-flow/watcher/ANALYZE.md.

        Showing the user:
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
        - speak: talk to the user out loud. Keep it to a sentence or two.

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

        // Refresh (or re-adopt) the caller's session on every request;
        // requests without a session header work as one anonymous pool.
        var session: MCPSession?
        if method != "initialize" {
            let (touched, isNew) = sessions.touch(sessionId)
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
            "Claude #N"). Call it once right after connecting, and again if your focus changes.
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
            "name": "ask_user",
            "description": """
            Ask the user something through Voice Flow and BLOCK until they answer. A floating \
            prompt appears on their screen; they can answer by voice (push-to-talk), voice plus \
            a fresh screenshot, typing in the Voice Flow panel, or by recording a demonstration \
            session (narration + ordered screenshots). The result contains their words plus \
            absolute file paths of any screenshots — read those files. Use when you cannot \
            proceed without their input. If you'd rather keep working while they decide, use \
            notify_user and collect the reply later with check_messages or wait_for_message. \
            The user may also tap "Seen — I'll answer later": you get that back immediately as \
            a non-error result — continue working and collect their eventual reply from the \
            message inbox.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "prompt": [
                        "type": "string",
                        "description": "What to ask. One or two short sentences — it appears in a small on-screen bubble and may be spoken aloud.",
                    ],
                    "speak_aloud": [
                        "type": "boolean",
                        "description": "Also speak the prompt via text-to-speech so the user hears it while looking elsewhere. Default false.",
                    ],
                    "timeout_seconds": [
                        "type": "number",
                        "description": "How long to wait before giving up, in seconds (10–3600). Default 900. Use longer when you asked for a demonstration.",
                    ],
                ],
                "required": ["prompt"],
            ],
        ],
        [
            "name": "notify_user",
            "description": """
            Show the user a short message in a floating on-screen bubble (optionally spoken) \
            and return IMMEDIATELY — the non-blocking counterpart of ask_user. To hear their \
            reply, park in wait_for_message: talk messages are delivered only while you are \
            listening. Use for status updates ("deploying now, ~2 min") and heads-ups that \
            need no reply.
            """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The message. Keep it short — it's a bubble, not a report."],
                    "speak_aloud": ["type": "boolean", "description": "Also speak it via text-to-speech. Default false."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "check_messages",
            "description": """
            Fetch (and clear) messages queued for you — deferred or late answers to your \
            ask_user prompts ("Seen — I'll answer later", answers after a timeout). Live talk \
            messages arrive only through wait_for_message, not here. Non-blocking. Messages \
            may include screenshot paths of what they were looking at — read them.
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
            non-error result — just call wait_for_message again to keep listening.
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
            "name": "speak",
            "description": "Say something to the user out loud through Voice Flow's text-to-speech. Use for short spoken updates while they work heads-down (\"done, tests pass\", \"step two is ready\"). Keep it to a sentence or two — this is voice, not a report.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "What to say."],
                ],
                "required": ["text"],
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
