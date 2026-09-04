import Cocoa

extension AppDelegate {
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  MCP tools — Voice Flow as Claude Code's interaction layer
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    //  Runs on a background HTTP thread; anything touching UI hops to main.
    //  a report_to_user question deliberately blocks — its result IS the user's answer.

    /// Tools whose call makes the session user-visible: it gets its picker
    /// dot, its ⌃⌥N slot, and voice-target eligibility. Read-only tools
    /// (screenshots, captures, dictations) and set_session_name do NOT
    /// engage — a session the user never hears from stays invisible.
    private static let engagingMCPTools: Set<String> = [
        "report_to_user", "wait_for_message",
        "show_guide", "update_guide", "show_panel", "annotate_screen",
    ]

    func handleMCPTool(_ name: String, _ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        if let session, Self.engagingMCPTools.contains(name),
           mcpServer.sessions.markEngaged(session.id) {
            // First engagement: surface the session. It claims the voice
            // target only when nobody engaged holds it — an active session
            // is never stolen from; the receipt's "⌃⌥N" is how the user
            // switches deliberately.
            DispatchQueue.main.sync {
                if self.targetSessionId == nil
                    || !self.pickerSessions().contains(where: { $0.id == self.targetSessionId }) {
                    self.setTargetSession(session.id, announce: false)
                }
                self.refreshSessionIndicator()
            }
        }
        let result = dispatchMCPTool(name, args, session)
        // Queued voice messages piggyback on every tool result so they
        // can't rot in the inbox unnoticed.
        guard !result.isError, let session,
              name != "check_messages", name != "wait_for_message" else { return result }
        let pending = inbox.pendingCount(for: session.id)
        guard pending > 0 else { return result }
        return .ok(result.text
            + "\n\n(\(pending) voice message\(pending == 1 ? "" : "s") from the user queued — call check_messages.)")
    }

    private func dispatchMCPTool(_ name: String, _ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        switch name {
        case "set_session_name": return mcpSetSessionName(args, session)
        case "report_to_user": return mcpReportToUser(args, session)
        case "check_messages": return mcpCheckMessages(session)
        case "wait_for_message": return mcpWaitForMessage(args, session)
        case "get_latest_capture": return mcpLatestCapture()
        case "list_captures": return mcpListCaptures(args)
        case "take_screenshot": return mcpTakeScreenshot(session)
        case "show_guide": return mcpShowGuide(args, session)
        case "update_guide": return mcpUpdateGuide(args, session)
        case "show_panel": return mcpShowPanel(args, session)
        case "annotate_screen": return mcpAnnotateScreen(args, session)
        case "clear_annotations":
            let removed = overlayManager.removeAll(annotationsOnly: true)
            DispatchQueue.main.sync { self.annotationOverlay.clear() }
            return .ok("Cleared \(removed) annotation overlay\(removed == 1 ? "" : "s") and the user's own marks.")
        case "remove_overlay": return mcpRemoveOverlay(args)
        case "list_overlays": return mcpListOverlays()
        case "get_recent_dictations": return mcpRecentDictations(args)
        default:
            return .fail("Unknown tool: \(name)")
        }
    }

    // Embedded OpenCode tools use this private bridge rather than public MCP,
    // so they never engage MCPSessionRegistry or create external picker state.
    func handleEmbeddedOverlayTool(
        _ args: [String: Any], conversationID: String
    ) async throws -> AgentToolOutput {
        let operation = try AgentToolDispatcher.requiredString("operation", in: args)
        let owner = assistantPickerSessionId ?? "assistant:\(conversationID)"
        let rawID = OverlayManager.sanitize(id: args["id"] as? String) ?? "agent"
        let id = "assistant-\(rawID)"
        switch operation {
        case "list":
            let items = overlayManager.list().compactMap { item -> [String: Any]? in
                guard overlayManager.read(id: item.id)?["session"] as? String == owner else { return nil }
                return ["id": item.id, "type": item.type, "path": item.path, "visible": item.visible]
            }
            return AgentToolOutput(data: ["overlays": items])
        case "remove":
            guard overlayManager.read(id: id)?["session"] as? String == owner else {
                throw AgentToolError.denied("overlay is not owned by this Assistant")
            }
            return AgentToolOutput(data: ["id": id, "removed": overlayManager.remove(id: id)])
        case "update_guide":
            guard var current = overlayManager.read(id: id),
                  current["session"] as? String == owner else {
                throw AgentToolError.denied("guide is not owned by this Assistant")
            }
            let payload = args["payload"] as? [String: Any] ?? [:]
            for (key, value) in payload { current[key] = value }
            current["type"] = "guide"
            current["session"] = owner
            guard let path = overlayManager.write(id: id, dict: current) else {
                throw AgentToolError.unavailable("overlay file could not be written")
            }
            return AgentToolOutput(data: ["id": id, "path": path, "updated": true])
        case "show_guide", "show_panel", "annotate":
            var payload = args["payload"] as? [String: Any] ?? [:]
            payload["type"] = operation == "show_guide" ? "guide"
                : operation == "show_panel" ? "panel" : "annotations"
            payload["session"] = owner
            guard JSONSerialization.isValidJSONObject(payload),
                  let encoded = try? JSONSerialization.data(withJSONObject: payload),
                  encoded.count <= 64 * 1_024 else {
                throw AgentToolError.invalidArguments("overlay payload is invalid or over 64 KiB")
            }
            guard let path = overlayManager.write(id: id, dict: payload) else {
                throw AgentToolError.unavailable("overlay file could not be written")
            }
            return AgentToolOutput(data: ["id": id, "path": path, "owner": owner])
        default:
            throw AgentToolError.invalidArguments("unsupported overlay operation")
        }
    }

    func handleEmbeddedUserTool(
        _ args: [String: Any], conversationID: String
    ) async throws -> AgentToolOutput {
        let operation = try AgentToolDispatcher.requiredString("operation", in: args)
        let owner = assistantPickerSessionId ?? "assistant:\(conversationID)"
        let summary = (args["summary"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let details = (args["details"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch operation {
        case "report":
            guard !summary.isEmpty else {
                throw AgentToolError.invalidArguments("report needs a non-empty summary")
            }
            let text = details.isEmpty ? summary : "\(summary)\n\n\(details)"
            await MainActor.run {
                self.agent.note("\(self.assistantPickerLabel): \(text)")
                if !self.surfaceBusy {
                    self.indicator.flashMessage("\(self.assistantPickerLabel) · update", seconds: 6)
                }
            }
            return AgentToolOutput(data: ["delivered": true, "channel": "assistant"])
        case "check":
            let messages = inbox.drain(session: owner)
            return AgentToolOutput(data: ["messages": messages.map {
                ["time": $0.time, "text": $0.text, "screenshots": $0.attachments] as [String: Any]
            }])
        case "ask", "wait":
            var prompt = (args["question"] as? String ?? summary)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if prompt.isEmpty { prompt = "The Assistant is waiting for your reply." }
            let requested = (args["timeout_seconds"] as? NSNumber)?.doubleValue
                ?? (operation == "ask" ? 1_800 : 600)
            let timeout = min(max(requested, 5), 14_400)
            var interaction: PendingInteraction?
            await MainActor.run {
                guard self.pendingInteraction == nil else { return }
                let value = PendingInteraction(prompt: prompt, sessionId: owner)
                self.pendingInteraction = value
                interaction = value
                self.replyBubble.showAsk(prompt: prompt, hint: self.askHint())
                self.agent.note("\(self.assistantPickerLabel) asks: \(prompt)")
            }
            guard let interaction else {
                throw AgentToolError.unavailable("another user question is already pending")
            }
            _ = interaction.semaphore.wait(timeout: .now() + timeout)
            return try await MainActor.run {
                interaction.resolved = true
                self.pendingInteraction = nil
                self.replyBubble.hide()
                if let response = interaction.responseText {
                    return AgentToolOutput(data: [
                        "response": response,
                        "screenshots": interaction.attachments,
                    ])
                }
                if interaction.cancelled {
                    throw AgentToolError.unavailable("the user dismissed the question")
                }
                throw AgentToolError.unavailable("no user response arrived before timeout")
            }
        default:
            throw AgentToolError.invalidArguments("unsupported user operation")
        }
    }

    private func mcpJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func mcpSetSessionName(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        guard let session else {
            return .fail("This request carried no session id, so there is nothing to name.")
        }
        var name = (args["name"] as? String ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return .fail("set_session_name needs a non-empty `name`.")
        }
        name = String(name.prefix(48))
        guard let renamed = mcpServer.sessions.rename(session.id, to: name) else {
            return .fail("This session is no longer registered.")
        }
        // Naming is silent by design: it must not create the impression of
        // a session the user should look at. The label surfaces whenever
        // the session actually engages.
        DispatchQueue.main.async {
            // A rename must reach existing threads' sticky titles too.
            if self.sessionLabels[renamed.id] != nil || self.sessionPushes[renamed.id] != nil {
                self.rememberSessionLabel(renamed.id)
            }
            self.refreshSessionIndicator()
        }
        return .ok("This session now appears to the user as \"\(renamed.label)\". You stay invisible to them until your first report_to_user / wait_for_message / overlay call.")
    }

    /// The one messaging tool: a receipt-backed report (summary + details),
    /// optionally blocking on a `question`.
    private func mcpReportToUser(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        let trimmed = { (key: String) in
            (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let summary = trimmed("summary")
        let details = trimmed("details")
        let question = trimmed("question")
        guard !summary.isEmpty else {
            return .fail("report_to_user needs a non-empty `summary` (and `details` with the substance — what happened, where, what you need).")
        }
        // The user reads one text: summary, then details, then the question
        // (skipped when it just repeats the summary).
        var parts = [summary]
        if !details.isEmpty { parts.append(details) }
        if !question.isEmpty, question != summary { parts.append(question) }
        let text = parts.joined(separator: "\n\n")

        guard !question.isEmpty else {
            let sessionId = session?.id
            DispatchQueue.main.sync {
                let sender = self.sessionName(for: sessionId)
                self.deliverPush(
                    SessionPush(title: sender, text: text, hint: nil, isAsk: false),
                    from: sessionId)
                if self.chatPanel.isVisible {
                    self.chatPanel.addNote("\(sender): \(text)")
                }
                self.playSound("Glass")
            }
            var reply = "Delivered: the user got a one-line receipt and reads the full report when they switch onto your session (⌃⌥N) or in the panel's Agents tab; audio plays only on their demand."
            if let sessionId {
                reply += """
                 If they might reply, start the reply listener as a background Bash task NOW — whether you keep working or are about to finish:
                ~/.claude/skills/communicate-with-user/scripts/vf listen --attach \(sessionId) --timeout 7200
                The moment they talk to your session it completes with their words and you are re-invoked. Without it, a reply sits queued until you happen to call another voice-flow tool — and can never reach you once you stop. Always start it fresh: it automatically replaces any earlier listener for this session (the old task ends itself with a superseded notice — ignore it).
                """
            }
            return .ok(reply)
        }

        var timeout = (args["timeout_seconds"] as? NSNumber)?.doubleValue ?? 1800
        timeout = min(max(timeout, 10), 14400)

        var interaction: PendingInteraction?
        DispatchQueue.main.sync {
            guard self.pendingInteraction == nil else { return }
            let created = PendingInteraction(prompt: text, sessionId: session?.id)
            self.pendingInteraction = created
            interaction = created
            let asker = self.sessionName(for: created.sessionId)
            // The ask lives ONLY in its session's thread (attached composer
            // is the signal) — never cross-posted into the assistant chat.
            self.deliverPush(
                SessionPush(title: "\(asker) asks", text: text,
                            hint: self.askHint(), isAsk: true),
                from: session?.id)
            if self.chatPanel.isVisible { self.chatPanel.refreshAgents() }
            self.playSound("Glass")
        }
        guard let interaction else {
            let busyWith = DispatchQueue.main.sync { self.pendingInteraction.map { self.sessionName(for: $0.sessionId) } }
            return .fail("\(busyWith ?? "Another session") is already blocking on a question — only one can wait at a time. Send your report without `question` now and collect the answer later via check_messages / wait_for_message.")
        }

        _ = interaction.semaphore.wait(timeout: .now() + timeout)

        var result = MCPServer.ToolResult.fail("Internal error resolving the interaction.")
        DispatchQueue.main.sync {
            interaction.resolved = true
            self.pendingInteraction = nil
            // The ask is settled either way. An ANSWERED ask stays with its
            // ↳ answer; an unanswered one (timeout / dismissed) DEGRADES to
            // a plain readable message instead of being deleted — threads
            // accumulate as history until the user completes them (Safet:
            // "nothing wrong with them, I want the history persistent").
            if let sid = interaction.sessionId {
                self.sessionPushes[sid] = self.sessionPushes[sid]?.map { push in
                    guard push.isAsk, push.answer == nil else { return push }
                    return SessionPush(at: push.at, title: push.title, text: push.text,
                                       hint: nil, isAsk: false, seen: push.seen,
                                       answer: nil, spoken: push.spoken, done: push.done)
                }
                self.refreshUnreadIndicator()
                self.chatPanel.refreshAgents()
            }
            if interaction.sessionId == nil || self.currentPushSessionId == interaction.sessionId {
                self.replyBubble.hide()
            }
            if let text = interaction.responseText {
                var payload: [String: Any] = ["response": text]
                if !interaction.attachments.isEmpty {
                    payload["screenshots"] = interaction.attachments
                    payload["note"] = "Screenshot file paths, in order — read them to see what the user showed you."
                }
                result = .ok(self.mcpJSON(payload))
            } else if interaction.cancelled {
                result = .fail("The user dismissed the prompt without answering. Don't immediately re-ask; continue as best you can or try another approach.")
            } else {
                self.replyBubble.showTransient("\(self.sessionName(for: interaction.sessionId)) stopped waiting", seconds: 6)
                result = .fail("The user didn't respond within \(Int(timeout))s. The prompt was removed from their screen.")
            }
        }
        return result
    }

    /// How a session is shown to the user: its self-chosen name when it has
    /// one, plain "Claude" when it's the only (unnamed) session, "Claude #N"
    /// otherwise. Looked up live so a later set_session_name call sticks.
    func sessionName(for id: String?) -> String {
        guard let session = mcpServer.sessions.session(id) else { return "Claude" }
        if session.name != nil { return session.label }
        // "#N" only disambiguates against sessions the user can SEE —
        // engaged ones and ghosts, not idle connections.
        return pickerSessions().count > 1 ? session.label : "Claude"
    }

    func askHint() -> String {
        let settings = UserSettings.shared
        return "Hold \(settings.hotkey.label) to answer · \(settings.snapshotHotkey.label) +screen · \(settings.continuousCaptureHotkey.label) continuous"
    }

    private func mcpLatestCapture() -> MCPServer.ToolResult {
        guard let (directory, meta) = CaptureStore.latestBundle() else {
            return .fail("No captures yet. The user records one with the continuous-capture hotkey — or asks for one with report_to_user (question).")
        }
        var payload: [String: Any] = [
            "id": meta.id,
            "directory": directory.path,
            "recorded_at": meta.startedAt,
            "duration_seconds": Int(meta.durationSeconds),
            "transcript": meta.transcript,
            "frames": meta.frames.map { directory.appendingPathComponent($0.file).path },
            "note": "Frames are ordered by time — read them alongside the transcript.",
        ]
        var recording = false
        DispatchQueue.main.sync { recording = self.captureStore.isCapturing }
        if recording {
            payload["warning"] = "A new session is being recorded right now; this is the latest COMPLETED capture."
        }
        return .ok(mcpJSON(payload))
    }

    private func mcpListCaptures(_ args: [String: Any]) -> MCPServer.ToolResult {
        let limit = min(max((args["limit"] as? NSNumber)?.intValue ?? 10, 1), 40)
        let bundles = CaptureStore.listBundles(limit: limit)
        guard !bundles.isEmpty else {
            return .ok("No captures recorded yet. The user records one with the continuous-capture hotkey, or you can request a demonstration via report_to_user (question).")
        }
        let items: [[String: Any]] = bundles.map { directory, meta in
            [
                "id": meta.id,
                "directory": directory.path,
                "recorded_at": meta.startedAt,
                "duration_seconds": Int(meta.durationSeconds),
                "frame_count": meta.frames.count,
                "transcript_preview": String(meta.transcript.prefix(160)),
            ]
        }
        return .ok(mcpJSON([
            "captures": items,
            "note": "Newest first. Each directory has transcript.md and a frames/ folder.",
        ]))
    }

    private func mcpTakeScreenshot(_ session: MCPSession?) -> MCPServer.ToolResult {
#if VOICE_FLOW_QA
        if let fixturePath = ProcessInfo.processInfo.environment["VOICE_FLOW_QA_SCREENSHOT_FIXTURE"],
           let raw = try? Data(contentsOf: URL(fileURLWithPath: fixturePath)),
           let shot = CaptureStore.saveShot(raw, on: DisplayTopology.primary) {
            let display = DisplayTopology.primary
            if let session, let display { lastMCPDisplay[session.id] = display.id }
            let cursor = display?.screenshotPoint(forGlobalPoint: NSEvent.mouseLocation) ?? .zero
            return .ok(mcpJSON([
                "path": shot.path,
                "width": shot.width,
                "height": shot.height,
                "display_id": Int(display?.id ?? 0),
                "cursor": [Int(cursor.x.rounded()), Int(cursor.y.rounded())],
                "note": "QA fixture captured through the same bounded screenshot store.",
            ]))
        }
#endif
        let semaphore = DispatchSemaphore(value: 0)
        var outcome = MCPServer.ToolResult.fail("Screenshot failed — screen recording permission may be missing.")
        Task { @MainActor in
            defer { semaphore.signal() }
            guard let display = DisplayTopology.underMouse ?? DisplayTopology.primary,
                  let raw = try? await self.screenCapture.captureScreen(on: display),
                  let shot = CaptureStore.saveShot(raw, on: display) else { return }
            if let session {
                self.lastMCPDisplay[session.id] = display.id
            }
            // Cursor position in the same pixel space as the saved image —
            // "circle the thing I'm pointing at" needs no extra round-trip.
            let cursor = display.screenshotPoint(forGlobalPoint: NSEvent.mouseLocation)
            outcome = .ok(self.mcpJSON([
                "path": shot.path,
                "width": shot.width,
                "height": shot.height,
                "display_id": Int(display.id),
                "cursor": [Int(cursor.x.rounded()), Int(cursor.y.rounded())],
                "note": "Read this file to see the screen. Overlay/annotation coordinates are pixels in this \(shot.width)x\(shot.height) image; `cursor` is where the user's pointer is right now.",
            ]))
        }
        _ = semaphore.wait(timeout: .now() + 15)
        return outcome
    }

    // ── Inbox tools ─────────────────────────────────────

    private func inboxPayload(_ messages: [InboxMessage]) -> String {
        mcpJSON([
            "messages": messages.map { message -> [String: Any] in
                var entry: [String: Any] = ["time": message.time, "text": message.text]
                if !message.attachments.isEmpty {
                    entry["screenshots"] = message.attachments
                }
                return entry
            },
            "note": "Oldest first. Screenshot paths show what the user was looking at — read them.",
        ])
    }

    private func mcpCheckMessages(_ session: MCPSession?) -> MCPServer.ToolResult {
        let messages = inbox.drain(session: session?.id)
        guard !messages.isEmpty else {
            return .ok("No messages from the user.")
        }
        return .ok(inboxPayload(messages))
    }

    private func mcpWaitForMessage(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        var timeout = (args["timeout_seconds"] as? NSNumber)?.doubleValue ?? 600
        timeout = min(max(timeout, 5), 3600)
        let (messages, superseded, terminated) = inbox.wait(timeout: timeout, session: session?.id)
        if superseded {
            return .ok("A newer listener took over this session. Nothing to do: say nothing, end your turn, do not restart this task.")
        }
        if terminated {
            return .ok("The user closed this session's listener. Nothing to do: say nothing, end your turn, do not restart this task.")
        }
        guard !messages.isEmpty else {
            return .ok("No message arrived within \(Int(timeout))s. That's normal — call wait_for_message again to keep listening, or move on.")
        }
        return .ok(inboxPayload(messages))
    }

    // ── Overlay tools (file-backed; see swift/Overlay.swift) ──

    private static func overlayStepDicts(_ raw: Any?) -> [[String: Any]]? {
        if let strings = raw as? [String], !strings.isEmpty {
            return strings.map { ["text": $0] }
        }
        guard let array = raw as? [[String: Any]] else { return nil }
        let steps = array.compactMap { dict -> [String: Any]? in
            guard let text = dict["text"] as? String,
                  !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            var step: [String: Any] = ["text": text]
            if let detail = dict["detail"] as? String, !detail.isEmpty {
                step["detail"] = detail
            }
            return step
        }
        return steps.isEmpty ? nil : steps
    }

    private func overlayWrittenResult(_ kind: String, id: String, path: String?, session: MCPSession?, extra: String = "") -> MCPServer.ToolResult {
        guard let path else {
            return .fail("Couldn't write the \(kind) overlay file.")
        }
        let visibility = notifyIfBackgroundOverlay(kind, session: session)
            ? "It is NOT on screen yet — the user is working with another session and was notified; they'll see it when they switch to you. "
            : "It is on the user's screen. "
        return .ok("\(kind.capitalized) \"\(id)\" written. \(visibility)\(extra)Its live file is \(path) — edit it directly (or via the tools) and the screen updates within ~0.5s; delete it (or remove_overlay) to dismiss. Schema: \(OverlayManager.schemaPath)")
    }

    /// A non-active session pushed something on screen — tell the user
    /// instead of drawing over what they're doing. Returns true when the
    /// element is hidden until they switch. Any thread.
    private func notifyIfBackgroundOverlay(_ kind: String, session: MCPSession?) -> Bool {
        guard let session else { return false }
        var hidden = false
        DispatchQueue.main.sync {
            hidden = session.id != self.targetSessionId
            // The note waits its turn like any receipt — never over grown
            // content or the user's recording.
            if hidden, !self.surfaceBusy {
                let index = self.pickerSessions().firstIndex { $0.id == session.id }
                let hint = index.map { " (⌃⌥\($0 + 1))" } ?? ""
                self.replyBubble.showTransient(
                    "\(self.sessionName(for: session.id)) placed a \(kind) — switch to it\(hint) to view.",
                    seconds: 8)
            }
        }
        return hidden
    }

    private func mcpShowGuide(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        guard let steps = Self.overlayStepDicts(args["steps"]) else {
            return .fail("show_guide needs a non-empty `steps` array of {text, detail?} objects.")
        }
        let id = OverlayManager.sanitize(id: args["id"] as? String) ?? "guide"
        var doc: [String: Any] = [
            "type": "guide",
            "title": args["title"] as? String ?? "Guide",
            "steps": steps,
            "active_step": max(1, (args["active_step"] as? NSNumber)?.intValue ?? 1),
            "position": args["position"] as? String ?? "center-right",
        ]
        if let note = args["note"] as? String, !note.isEmpty {
            doc["note"] = note
        }
        if let session {
            doc["session"] = session.id
        }
        let path = overlayManager.write(id: id, dict: doc)
        return overlayWrittenResult("guide", id: id, path: path, session: session,
                                    extra: "\(steps.count) steps. Advance with update_guide as the user progresses. ")
    }

    private func mcpUpdateGuide(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        let id = OverlayManager.sanitize(id: args["id"] as? String) ?? "guide"
        guard var doc = overlayManager.read(id: id), doc["type"] as? String == "guide" else {
            return .fail("No guide overlay \"\(id)\" exists — call show_guide first.")
        }
        if let active = (args["active_step"] as? NSNumber)?.intValue {
            doc["active_step"] = max(1, active)
        }
        if let note = args["note"] as? String {
            if note.isEmpty { doc.removeValue(forKey: "note") } else { doc["note"] = note }
        }
        if let title = args["title"] as? String, !title.isEmpty {
            doc["title"] = title
        }
        if let steps = Self.overlayStepDicts(args["steps"]) {
            doc["steps"] = steps
        }
        if let position = args["position"] as? String, !position.isEmpty {
            doc["position"] = position
        }
        guard overlayManager.write(id: id, dict: doc) != nil else {
            return .fail("Couldn't write the guide overlay file.")
        }
        return .ok("Guide \"\(id)\" updated.")
    }

    private func mcpShowPanel(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        guard let rawBlocks = args["blocks"] as? [[String: Any]], !rawBlocks.isEmpty else {
            return .fail("show_panel needs a non-empty `blocks` array.")
        }
        let validKinds: Set<String> = ["heading", "text", "code", "bullets"]
        let blocks = rawBlocks.filter { validKinds.contains($0["kind"] as? String ?? "") }
        guard !blocks.isEmpty else {
            return .fail("No valid blocks — each needs kind heading|text|code|bullets plus text (or items for bullets).")
        }
        let id = OverlayManager.sanitize(id: args["id"] as? String) ?? "panel"
        var doc: [String: Any] = [
            "type": "panel",
            "blocks": blocks,
            "position": args["position"] as? String ?? "center-right",
        ]
        if let title = args["title"] as? String, !title.isEmpty {
            doc["title"] = title
        }
        if let note = args["note"] as? String, !note.isEmpty {
            doc["note"] = note
        }
        if let width = (args["width"] as? NSNumber)?.doubleValue {
            doc["width"] = min(max(width, 240), 620)
        }
        if let session {
            doc["session"] = session.id
        }
        let path = overlayManager.write(id: id, dict: doc)
        return overlayWrittenResult("panel", id: id, path: path, session: session)
    }

    private func mcpAnnotateScreen(_ args: [String: Any], _ session: MCPSession?) -> MCPServer.ToolResult {
        guard let actions = args["actions"] as? [[String: Any]], !actions.isEmpty else {
            return .fail("annotate_screen needs a non-empty `actions` array.")
        }
        var valid: [[String: Any]] = []
        var problems: [String] = []
        for (index, action) in actions.enumerated() {
            if OverlayShape.parse(action) != nil {
                valid.append(action)
            } else {
                problems.append("actions[\(index)] (\(action["type"] as? String ?? "?")) is malformed — see the annotate_screen schema")
            }
        }
        guard !valid.isEmpty else {
            return .fail("No valid actions. " + problems.joined(separator: "; "))
        }

        let id = OverlayManager.sanitize(id: args["id"] as? String) ?? "annotations"
        let clearFirst = args["clear_first"] as? Bool ?? false
        var items = valid
        if !clearFirst,
           let existing = overlayManager.read(id: id),
           existing["type"] as? String == "annotations",
           let previous = existing["items"] as? [[String: Any]] {
            items = previous + valid
        }
        var annotationsDoc: [String: Any] = ["type": "annotations", "items": items]
        if let existing = overlayManager.read(id: id),
           let displayId = existing["display_id"] as? NSNumber,
           !clearFirst {
            annotationsDoc["display_id"] = displayId
        } else if let session, let displayId = lastMCPDisplay[session.id] {
            annotationsDoc["display_id"] = Int(displayId)
        } else if let display = DisplayTopology.primary {
            annotationsDoc["display_id"] = Int(display.id)
        }
        if let session {
            annotationsDoc["session"] = session.id
        }
        let path = overlayManager.write(id: id, dict: annotationsDoc)
        guard let path else {
            return .fail("Couldn't write the annotations overlay file.")
        }
        let hidden = notifyIfBackgroundOverlay("drawing", session: session)
        var text = hidden
            ? "Drew \(valid.count) shape\(valid.count == 1 ? "" : "s") (\(items.count) total in overlay \"\(id)\") — NOT visible yet: the user is on another session and was notified; they'll see them when they switch to you. Live file: \(path)"
            : "Drew \(valid.count) shape\(valid.count == 1 ? "" : "s") on the user's screen (\(items.count) total in overlay \"\(id)\"). They stay visible — and appear in screenshots — until cleared. Live file: \(path)"
        if !problems.isEmpty {
            text += " Skipped: " + problems.joined(separator: "; ")
        }
        return .ok(text)
    }

    private func mcpRemoveOverlay(_ args: [String: Any]) -> MCPServer.ToolResult {
        guard let rawId = args["id"] as? String, !rawId.isEmpty else {
            return .fail("remove_overlay needs an `id` (or \"all\").")
        }
        if rawId == "all" {
            let removed = overlayManager.removeAll(annotationsOnly: false)
            return .ok("Removed \(removed) overlay\(removed == 1 ? "" : "s") from the user's screen.")
        }
        guard let id = OverlayManager.sanitize(id: rawId) else {
            return .fail("Invalid overlay id.")
        }
        guard overlayManager.remove(id: id) else {
            return .fail("No overlay \"\(id)\" exists. list_overlays shows what's on screen.")
        }
        return .ok("Overlay \"\(id)\" removed.")
    }

    private func mcpListOverlays() -> MCPServer.ToolResult {
        let overlays = overlayManager.list()
        guard !overlays.isEmpty else {
            return .ok("No overlays on screen. Create one with show_guide / show_panel / annotate_screen, or write a JSON file into \(OverlayManager.dir.path) (schema: \(OverlayManager.schemaPath)).")
        }
        return .ok(mcpJSON([
            "overlays": overlays.map { overlay -> [String: Any] in
                ["id": overlay.id, "type": overlay.type, "path": overlay.path, "visible": overlay.visible]
            },
            "note": "Edit any file directly and the screen re-renders within ~0.5s. Schema: \(OverlayManager.schemaPath)",
        ]))
    }

    private func mcpRecentDictations(_ args: [String: Any]) -> MCPServer.ToolResult {
        let limit = min(max((args["limit"] as? NSNumber)?.intValue ?? 10, 1), 50)
        let entries = DictationsView.recentEntries(limit: limit)
        guard !entries.isEmpty else {
            return .ok("No dictations recorded yet.")
        }
        return .ok(mcpJSON([
            "dictations": entries.map { ["time": $0.time, "text": $0.text] },
            "note": "Newest first; times are HH:mm:ss, local, from today's app session or earlier.",
        ]))
    }

    func makeTTSStatusResponse() -> LocalAPIResponse {
        let request = chatPanel.currentTTSRequest()
        let status = ttsController.status
        return LocalAPIResponse.ok([
            "ok": true,
            "phase": status.phase.rawValue,
            "message": status.message,
            "position": status.currentTime,
            "duration": status.duration,
            "has_audio": status.hasAudio,
            "is_cached": status.isCached,
            "text": request.text,
            "voice": request.voice,
            "speed": request.speed,
            "instructions": request.instructions,
            "has_openai_api_key": KeychainStore.shared.hasOpenAIAPIKey,
            "api_base_url": localAPIServer.baseURL,
            "endpoints": [
                "GET /api/tts/status",
                "POST /api/tts/set",
                "POST /api/tts/speak",
                "POST /api/tts/seek",
                "POST /api/tts/stop",
            ],
        ])
    }
}
