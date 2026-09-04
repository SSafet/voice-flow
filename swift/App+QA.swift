#if VOICE_FLOW_QA
import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  QA control surface — the /__qa/* endpoints the signed test build
//  serves (compile-time only; see tests/e2e_agent_harness.py).
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension AppDelegate {
    private func qaObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data.isEmpty ? [:] : nil
        }
        return value
    }

    func handleQAControl(method: String, path: String,
                                 body: Data) -> LocalAPIResponse {
        guard let payload = qaObject(body) else {
            return .error(400, "Request body must be a JSON object.")
        }
        switch (method, path) {
        case ("GET", "/__qa/state"):
            return .ok(qaState())
        case ("GET", "/__qa/events"):
            let after = (payload["after"] as? NSNumber)?.intValue ?? 0
            return .ok(["events": QAEventRecorder.shared.snapshot(after: after)])
        case ("POST", "/__qa/events/reset"):
            QAEventRecorder.shared.reset()
            return .ok(["ok": true])
        case ("GET", "/__qa/capabilities"):
            let candidates = [
                Bundle.main.resourceURL?.appendingPathComponent("QA/capabilities.json"),
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("tests/capabilities.json"),
            ].compactMap { $0 }
            guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error(503, "QA capability catalog is not bundled.")
            }
            return .ok(catalog)
        case ("POST", "/__qa/conversation/create"):
            var response = LocalAPIResponse.error(409, "Assistant is running.")
            DispatchQueue.main.sync {
                guard !self.agent.isRunning else { return }
                let conversation = self.agent.createConversation(
                    force: payload["force"] as? Bool ?? false)
                self.chatPanel.restoreAssistantConversation(conversation, open: true)
                response = .ok(["conversation_id": conversation.id])
            }
            return response
        case ("POST", "/__qa/conversation/select"):
            guard let id = payload["conversation_id"] as? String else {
                return .error(400, "conversation_id is required.")
            }
            var response = LocalAPIResponse.error(404, "Conversation not found or busy.")
            DispatchQueue.main.sync {
                if let conversation = self.agent.activateConversation(id) {
                    self.chatPanel.restoreAssistantConversation(conversation, open: true)
                    response = .ok(["conversation_id": id])
                }
            }
            return response
        case ("POST", "/__qa/runtime"):
            guard let raw = payload["runtime"] as? String,
                  let runtime = AgentRuntimeKind(rawValue: raw) else {
                return .error(400, "runtime must be codex or opencode.")
            }
            let trust = (payload["trust_profile"] as? String)
                .flatMap(AgentTrustProfile.init(rawValue:)) ?? .workspace
            var response = LocalAPIResponse.error(409, "Assistant is running.")
            DispatchQueue.main.sync {
                self.agent.qaTrustProfile = trust
                if self.agent.setPreferredRuntime(runtime) != nil {
                    self.chatPanel.refreshAgents()
                    response = .ok(["runtime": runtime.rawValue, "trust_profile": trust.rawValue])
                }
            }
            return response
        case ("POST", "/__qa/runtime/default"):
            guard let raw = payload["runtime"] as? String,
                  let runtime = AgentRuntimeKind(rawValue: raw) else {
                return .error(400, "runtime must be codex or opencode.")
            }
            UserSettings.shared.agentBackend = runtime.rawValue
            UserSettings.shared.save()
            return .ok(["runtime": runtime.rawValue])
        case ("GET", "/__qa/runtime/health"):
            let semaphore = DispatchSemaphore(value: 0)
            var values: [[String: Any]] = []
            Task {
                for runtime in AgentRuntimeKind.allCases {
                    let status: AgentRuntimeStatus
                    switch runtime {
                    case .codex: status = await CodexAgentRuntime().status()
                    case .opencode: status = await OpenCodeAgentRuntime().status()
                    }
                    values.append([
                        "runtime": runtime.rawValue,
                        "health": status.health.rawValue,
                        "version": status.version ?? "",
                        "detail": status.detail ?? "",
                    ])
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 5) == .success else {
                return .error(504, "runtime health check timed out.")
            }
            return .ok(["runtimes": values])
        case ("GET", "/__qa/assistant/tail"):
            var response: [String: Any] = [:]
            DispatchQueue.main.sync {
                let conversation = self.agent.currentConversation
                response = [
                    "conversation_id": conversation.id,
                    "message_count": conversation.messages.count,
                    "messages": conversation.messages.suffix(8).map { message in
                        [
                            "role": message.role.rawValue,
                            "text": String(AgentSecretPolicy.redacted(message.text).prefix(4_000)),
                        ]
                    },
                    "running": self.agent.isRunning,
                ]
            }
            return .ok(response)
        case ("POST", "/__qa/provider"):
            guard let base = payload["base_url"] as? String,
                  let url = URL(string: base),
                  url.host == "127.0.0.1" || url.host == "localhost",
                  let model = payload["model"] as? String,
                  !model.isEmpty else {
                return .error(400, "QA provider must be a loopback base_url and non-empty model.")
            }
            UserSettings.shared.agentBaseURL = url.absoluteString
            UserSettings.shared.agentModel = model
            if let budget = (payload["daily_budget_usd"] as? NSNumber)?.doubleValue {
                UserSettings.shared.agentDailyBudgetUSD = max(0, budget)
            }
            UserSettings.shared.save()
            return .ok(["base_url": url.absoluteString, "model": model])
        case ("POST", "/__qa/submit"):
            let text = payload["text"] as? String
            let paths = payload["screenshots"] as? [String] ?? []
            var images: [Data] = []
            for path in paths {
                let url = URL(fileURLWithPath: path).standardizedFileURL
                guard VoiceFlowPaths.shared.contains(url),
                      let data = try? Data(contentsOf: url), data.count <= 20_000_000 else {
                    return .error(403, "Every screenshot must be a bounded file inside the QA root.")
                }
                images.append(data)
            }
            var response = LocalAPIResponse.error(409, "Assistant is running.")
            DispatchQueue.main.sync {
                guard !self.agent.isRunning else { return }
                self.agent.send(text: text, screenshots: images)
                response = .accepted([
                    "conversation_id": self.agent.currentSessionId,
                    "runtime": self.agent.preferredRuntime.rawValue,
                ])
            }
            return response
        case ("POST", "/__qa/hotkey/post"):
            guard let rawKeyCode = (payload["key_code"] as? NSNumber)?.intValue,
                  (0...127).contains(rawKeyCode),
                  let action = payload["action"] as? String,
                  HotkeyManager.qaPost(keyCode: CGKeyCode(rawKeyCode), action: action) else {
                return .error(400, "key_code 0...127 and action press|release|tap|double_tap are required.")
            }
            return .accepted(["key_code": rawKeyCode, "action": action])
        case ("POST", "/__qa/interrupt"):
            DispatchQueue.main.sync { self.agent.interrupt() }
            return .accepted(["interrupt_requested": true])
        case ("POST", "/__qa/permission"):
            guard let id = payload["id"] as? String,
                  let raw = payload["response"] as? String,
                  let response = AgentPermissionResponse(rawValue: raw) else {
                return .error(400, "id and response (once|reject) are required.")
            }
            Task { await AgentPermissionBroker.shared.resolve(id: id, response: response) }
            return .accepted(["permission_id": id, "response": raw])
        case ("POST", "/__qa/opencode/stop"):
            let profile = (payload["trust_profile"] as? String)
                .flatMap(AgentTrustProfile.init(rawValue:))
            Task {
                if let profile { await OpenCodeSupervisor.shared.stop(profile: profile) }
                else { await OpenCodeSupervisor.shared.stopAll() }
                QAEventRecorder.shared.append("opencode_stopped")
            }
            return .accepted(["stop_requested": true])
        case ("POST", "/__qa/opencode/restart"):
            let profile = (payload["trust_profile"] as? String)
                .flatMap(AgentTrustProfile.init(rawValue:)) ?? .workspace
            Task {
                await OpenCodeSupervisor.shared.stop(profile: profile)
                do {
                    let connection = try await OpenCodeSupervisor.shared.connection(for: profile)
                    QAEventRecorder.shared.append(
                        "opencode_restarted", ["version": connection.version])
                } catch {
                    QAEventRecorder.shared.append(
                        "opencode_restart_failed", ["error": error.localizedDescription])
                }
            }
            return .accepted(["restart_requested": true, "trust_profile": profile.rawValue])
        case ("GET", "/__qa/jobs"):
            return .ok(["jobs": qaJobs()])
        case ("POST", "/__qa/automation/editor"):
            let action = payload["action"] as? String ?? "open"
            if action == "open" {
                let configured = UserSettings.shared.agentBaseURL
                let baseURL = URL(string: configured) ?? URL(string: DefaultAgentBaseURL)!
                let defaultModel = UserSettings.shared.agentModel
                var fallbackIDs: Set<String> = [defaultModel]
                if let store = agentJobStore, let jobs = try? store.jobs(limit: 500) {
                    fallbackIDs.formUnion(jobs.compactMap(\.modelID))
                }
                Task {
                    let models = await OpenRouterModelCatalog.shared.refresh(
                        baseURL: baseURL,
                        apiKey: KeychainStore.shared.loadAgentAPIKey(),
                        fallbackIDs: fallbackIDs)
                    await MainActor.run {
                        let editor = AgentJobEditorView(
                            models: models, preferredRuntime: self.agent.preferredRuntime,
                            defaultModelID: defaultModel,
                            defaultReasoningEffort: UserSettings.shared.agentReasoningEffort)
                        let window = NSPanel(
                            contentRect: NSRect(x: 0, y: 0, width: 500, height: 277),
                            styleMask: [.titled, .closable], backing: .buffered,
                            defer: false)
                        window.title = "New automation"
                        window.contentView = editor
                        window.center()
                        window.orderFrontRegardless()
                        self.activeAgentJobQAWindow = window
                        self.activeAgentJobEditor = editor
                        QAEventRecorder.shared.append("automation_editor_presented")
                    }
                }
                return .accepted(["opening": true])
            }
            if action == "close" {
                DispatchQueue.main.async {
                    if let window = self.activeAgentJobQAWindow {
                        window.close()
                        self.activeAgentJobQAWindow = nil
                        self.activeAgentJobEditor = nil
                    } else if let alert = self.activeAgentJobAlert {
                        NSApp.abortModal()
                        alert.window.orderOut(nil)
                    }
                }
                return .accepted(["closing": true])
            }
            if action == "search", let query = payload["query"] as? String {
                var accepted = false
                DispatchQueue.main.sync {
                    guard let editor = self.activeAgentJobEditor else { return }
                    editor.modelCombo.stringValue = query
                    editor.modelCombo.controlTextDidChange(Notification(
                        name: NSControl.textDidChangeNotification,
                        object: editor.modelCombo))
                    accepted = true
                }
                return accepted ? .ok(["query": query])
                    : .error(409, "Automation editor is not visible.")
            }
            if action == "select_model", let modelID = payload["model_id"] as? String {
                var selected = false
                DispatchQueue.main.sync {
                    selected = self.activeAgentJobEditor?.qaSelectModel(id: modelID) ?? false
                }
                return selected ? .ok(["model_id": modelID])
                    : .error(400, "model_id is not in the current picker catalog.")
            }
            if action == "select_runtime", let runtime = payload["runtime"] as? String {
                var selected = false
                DispatchQueue.main.sync {
                    guard let editor = self.activeAgentJobEditor,
                          let kind = AgentRuntimeKind(rawValue: runtime) else { return }
                    editor.qaSelectRuntime(kind)
                    selected = true
                }
                return selected ? .ok(["runtime": runtime])
                    : .error(400, "runtime must be codex or opencode.")
            }
            if action == "select_trigger", let trigger = payload["trigger"] as? String {
                let labels = [
                    "manual": "Manual", "interval": "Interval",
                    "daily": "Daily at time",
                    "inbox": "Inbox message", "capture": "Capture completed",
                    "watcher": "Watcher action",
                ]
                var selected = false
                DispatchQueue.main.sync {
                    guard let editor = self.activeAgentJobEditor,
                          let label = labels[trigger] else { return }
                    editor.qaSetVisibleTrigger(label)
                    selected = true
                }
                return selected ? .ok(["trigger": trigger])
                    : .error(400, "trigger is not supported.")
            }
            return .error(
                400,
                "action must be open, search, select_model, select_runtime, select_trigger, or close.")
        case ("POST", "/__qa/automation/editor_snapshot"):
            var response = LocalAPIResponse.error(409, "Automation editor is not visible.")
            DispatchQueue.main.sync {
                guard let editor = self.activeAgentJobEditor else { return }
                do {
                    let shot = try editor.qaSnapshot()
                    response = .ok([
                        "path": shot.path, "width": shot.width, "height": shot.height,
                    ])
                } catch {
                    response = .error(500, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/settings/assistant"):
            let action = payload["action"] as? String ?? "open"
            var response = LocalAPIResponse.error(400, "Unknown Settings action.")
            DispatchQueue.main.sync {
                switch action {
                case "open":
                    self.settingsWindow.qaShowAssistant()
                    response = .accepted(["opening": true])
                case "close":
                    self.settingsWindow.qaClose()
                    response = .accepted(["closing": true])
                case "select_model":
                    guard let id = payload["model_id"] as? String,
                          self.settingsWindow.qaSelectModel(id: id) else {
                        response = .error(400, "model_id is not in the Settings catalog.")
                        return
                    }
                    response = .ok(["model_id": id])
                default:
                    break
                }
            }
            return response
        case ("POST", "/__qa/settings/snapshot"):
            var response = LocalAPIResponse.error(409, "Assistant Settings is not visible.")
            DispatchQueue.main.sync {
                guard self.settingsWindow.qaAssistantVisible else { return }
                do {
                    let shot = try self.settingsWindow.qaSnapshot()
                    response = .ok([
                        "path": shot.path, "width": shot.width, "height": shot.height,
                    ])
                } catch {
                    response = .error(500, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/jobs/create"):
            guard let prompt = payload["prompt"] as? String,
                  !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let assistant = agent.activeAssistant,
                  let agentJobStore else {
                return .error(400, "prompt, active assistant, and job store are required.")
            }
            let runtime = (payload["runtime"] as? String)
                .flatMap(AgentRuntimeKind.init(rawValue:)) ?? agent.preferredRuntime
            let trigger = (payload["trigger"] as? String)
                .flatMap(AgentJobTriggerKind.init(rawValue:)) ?? .manual
            let interval = (payload["interval_seconds"] as? NSNumber)?.doubleValue
            let dailyTime = (payload["daily_time_minutes"] as? NSNumber)?.intValue
            let now = Date()
            let nextRun = AgentJob.nextScheduledRun(
                trigger: trigger,
                intervalSeconds: max(1, interval ?? 60),
                dailyTimeMinutes: dailyTime ?? 8 * 60, after: now)
            let job = AgentJob(
                assistantSlug: assistant.slug,
                conversationID: (payload["conversation_id"] as? String) ?? agent.currentSessionId,
                runtime: runtime, trigger: trigger,
                modelID: runtime == .opencode ? payload["model_id"] as? String : nil,
                prompt: prompt,
                trustProfile: (payload["trust_profile"] as? String)
                    .flatMap(AgentTrustProfile.init(rawValue:)) ?? .unattended,
                state: nextRun == nil ? .completed : .queued,
                nextRunAt: nextRun,
                intervalSeconds: trigger == .interval ? max(1, interval ?? 60) : nil,
                dailyTimeMinutes: trigger == .daily ? dailyTime ?? 8 * 60 : nil,
                concurrencyKey: payload["concurrency_key"] as? String,
                dailyBudgetUSD: (payload["daily_budget_usd"] as? NSNumber)?.doubleValue ?? 1,
                maxDurationSeconds: (payload["max_duration_seconds"] as? NSNumber)?.doubleValue ?? 900,
                maxAttempts: (payload["max_attempts"] as? NSNumber)?.intValue ?? 3,
                createdAt: now, updatedAt: now)
            do {
                try agentJobStore.put(job)
                return .ok(["job_id": job.id])
            } catch {
                return .error(400, error.localizedDescription)
            }
        case ("POST", "/__qa/jobs/run"):
            guard let id = payload["job_id"] as? String else {
                return .error(400, "job_id is required.")
            }
            runAgentJob(id)
            return .accepted(["job_id": id])
        case ("POST", "/__qa/jobs/cancel"):
            guard let id = payload["job_id"] as? String else {
                return .error(400, "job_id is required.")
            }
            cancelAgentJob(id)
            return .accepted(["job_id": id])
        case ("POST", "/__qa/jobs/trigger"):
            guard let raw = payload["trigger"] as? String,
                  let trigger = AgentJobTriggerKind(rawValue: raw),
                  trigger != .manual && trigger != .interval && trigger != .daily else {
                return .error(400, "trigger must be inbox, capture, or watcher.")
            }
            let eventID = (payload["event_id"] as? String) ?? UUID().uuidString
            enqueueAgentJobs(trigger: trigger, source: "qa-\(raw)", eventID: eventID)
            return .accepted(["trigger": raw, "event_id": eventID])
        case ("POST", "/__qa/inbox/add"):
            guard let text = payload["text"] as? String, !text.isEmpty else {
                return .error(400, "text is required.")
            }
            inbox.add(text: text, attachments: [], session: nil)
            return .accepted(["queued": true])
        case ("POST", "/__qa/capture/finalize"):
            guard let transcript = payload["transcript"] as? String, !transcript.isEmpty else {
                return .error(400, "transcript is required.")
            }
            var captureID = ""
            DispatchQueue.main.sync {
                self.captureStore.beginSession(runId: UUID())
                captureID = self.captureStore.endSession(
                    transcript: transcript, keepEmpty: true)?.id ?? ""
            }
            guard !captureID.isEmpty else { return .error(500, "capture did not finalize.") }
            return .accepted(["capture_id": captureID])
        case ("POST", "/__qa/capture/deliver"):
            guard let rawCapability = payload["capability"] as? String,
                  let capability = CaptureCapability(rawValue: rawCapability),
                  let routeName = payload["route"] as? String,
                  let transcript = payload["transcript"] as? String,
                  !transcript.isEmpty else {
                return .error(400, "capability, route, and transcript are required.")
            }
            let fixtureData: Data?
            if let fixturePath = payload["fixture_path"] as? String {
                let fixtureURL = URL(fileURLWithPath: fixturePath).standardizedFileURL
                guard VoiceFlowPaths.shared.contains(fixtureURL),
                      let data = try? Data(contentsOf: fixtureURL), data.count <= 20_000_000 else {
                    return .error(403, "fixture_path must be a bounded file in the QA root.")
                }
                fixtureData = data
            } else {
                fixtureData = nil
            }
            var response = LocalAPIResponse.error(400, "unknown capture route.")
            DispatchQueue.main.sync {
                let route: CaptureRoute
                switch routeName {
                case "history": route = .historyOnly
                case "assistant": route = .assistant
                case "closed_paste":
                    route = .paste(PasteTarget(
                        processIdentifier: pid_t.max, name: "Closed QA target"))
                default: return
                }
                let id = UUID()
                var snapshot: SnapshotState = capability == .snapshot ? .unavailable : .notNeeded
                if capability == .snapshot, let data = fixtureData,
                   let shot = CaptureStore.saveShot(data) {
                    snapshot = .captured(path: shot.path, data: data)
                }
                var run = CaptureRun(
                    id: id, capability: capability, route: route, startedAt: Date(),
                    display: DisplayTopology.primary, snapshot: snapshot)
                run.transcript = transcript
                run.phase = .ready
                if capability == .continuous {
                    self.captureStore.beginSession(runId: id)
                    if let data = fixtureData {
                        self.captureStore.addFrame(data)
                        run.continuousScreenshots = [data]
                    }
                    run.continuousSummary = self.captureStore.endSession(
                        transcript: nil, keepEmpty: true)
                }
                self.captureRuns[id] = run
                self.maybeDeliverCapture(id)
                response = .accepted([
                    "run_id": id.uuidString,
                    "capability": capability.rawValue,
                    "route": routeName,
                ])
            }
            return response
        case ("POST", "/__qa/watcher/action"):
            let eventID = (payload["event_id"] as? String) ?? UUID().uuidString
            DispatchQueue.main.sync { self.workflowWatcher.emitQAAction(id: eventID) }
            return .accepted(["event_id": eventID])
        case ("POST", "/__qa/tts/action"):
            guard let action = payload["action"] as? String else {
                return .error(400, "action is required.")
            }
            var accepted = true
            DispatchQueue.main.sync {
                switch action {
                case "pause": self.ttsController.pause()
                case "resume":
                    if self.ttsController.isPaused { self.ttsController.togglePause() }
                case "seek":
                    self.ttsController.seek(to: (payload["position"] as? NSNumber)?.doubleValue ?? 0)
                case "stop": self.ttsController.stop()
                case "voice_replies_on":
                    UserSettings.shared.voiceRepliesEnabled = true
                    UserSettings.shared.save()
                    self.chatPanel.setVoiceReplies(true)
                case "voice_replies_off":
                    UserSettings.shared.voiceRepliesEnabled = false
                    UserSettings.shared.save()
                    self.chatPanel.setVoiceReplies(false)
                case "live_begin": self.replySpeaker.begin()
                case "live_feed":
                    guard let text = payload["text"] as? String, !text.isEmpty else {
                        accepted = false
                        return
                    }
                    self.replySpeaker.append(text)
                case "live_finish": self.replySpeaker.finish()
                default: accepted = false
                }
            }
            return accepted ? .accepted(["action": action]) : .error(400, "unknown TTS action.")
        case ("POST", "/__qa/panel"):
            let tab = payload["tab"] as? String
            DispatchQueue.main.sync {
                if tab == "hide" {
                    self.chatPanel.hide()
                } else {
                    self.chatPanel.show(focusInput: false)
                    if tab == "inbox" { self.chatPanel.selectTab(.inbox) }
                    else if tab == "agents" {
                        let destination = payload["agents_destination"] as? String ?? "now"
                        _ = self.chatPanel.qaShowAgents(
                            destination: destination,
                            automationAction: payload["automation_action"] as? String,
                            jobID: payload["job_id"] as? String,
                            threadSource: payload["thread_source"] as? String,
                            threadID: payload["thread_id"] as? String,
                            threadFilter: payload["thread_filter"] as? String,
                            systemAgent: payload["system_agent"] as? String)
                    }
                }
            }
            return .ok(["shown": tab ?? "current"])
        case ("GET", "/__qa/system_agents"):
            var state: [String: Any] = [:]
            DispatchQueue.main.sync { state = self.chatPanel.qaSystemAgentState() }
            return .ok(state)
        case ("POST", "/__qa/system_agent"):
            var handled = true
            var state: [String: Any] = [:]
            DispatchQueue.main.sync {
                if payload["model"] != nil || payload["effort"] != nil
                    || payload["instructions"] != nil {
                    handled = self.chatPanel.qaSystemAgentEdit(
                        model: payload["model"] as? String,
                        effort: payload["effort"] as? String,
                        instructions: payload["instructions"] as? String)
                }
                if handled, let action = payload["action"] as? String {
                    handled = self.chatPanel.qaSystemAgentAction(action)
                }
                state = self.chatPanel.qaSystemAgentState()
            }
            return handled ? .ok(state) : .error(409, "no system agent editor is open.")
        case ("GET", "/__qa/agents/navigation"):
            var state: [String: Any] = [:]
            DispatchQueue.main.sync { state = self.chatPanel.qaAgentsNavigationState }
            return .ok(state)
        case ("POST", "/__qa/thread/ui_action"):
            guard let action = payload["action"] as? String, !action.isEmpty else {
                return .error(400, "action is required.")
            }
            var handled = false
            DispatchQueue.main.sync { handled = self.chatPanel.qaThreadUIAction(action) }
            return handled ? .ok(["action": action]) : .error(400, "unknown thread ui action.")
        case ("POST", "/__qa/thread/compose"):
            guard let text = payload["text"] as? String else {
                return .error(400, "text is required.")
            }
            var composed = false
            DispatchQueue.main.sync { composed = self.chatPanel.qaSetAgentsComposerText(text) }
            return composed ? .ok(["ok": true]) : .error(409, "no thread composer is open.")
        case ("POST", "/__qa/thread/action"):
            guard let sourceRaw = payload["source"] as? String,
                  let source = AgentsThreadSource(rawValue: sourceRaw),
                  let idValue = payload["id"] as? String, !idValue.isEmpty,
                  let action = payload["action"] as? String else {
                return .error(400, "source, id, and action are required.")
            }
            let id = AgentsThreadID(source: source, value: idValue)
            var response = LocalAPIResponse.error(400, "unknown thread action.")
            DispatchQueue.main.sync {
                do {
                    switch action {
                    case "complete": try self.completeThread(id)
                    case "reopen": try self.reopenThread(id)
                    case "delete": try self.deleteThread(id)
                    case "send":
                        guard let text = payload["text"] as? String, !text.isEmpty else {
                            response = .error(400, "send requires text.")
                            return
                        }
                        try self.sendMessage(toThread: id, text: text)
                    default: return
                    }
                    response = .accepted([
                        "source": source.rawValue, "id": idValue, "action": action,
                    ])
                } catch {
                    response = .error(409, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/overlay/user_close"):
            guard let id = payload["id"] as? String,
                  let sanitized = OverlayManager.sanitize(id: id), sanitized == id else {
                return .error(400, "a sanitized overlay id is required.")
            }
            DispatchQueue.main.sync { self.overlayManager.qaClose(id: id) }
            return .accepted(["id": id])
        case ("POST", "/__qa/mcp/select"):
            guard let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else {
                return .error(400, "session_id is required.")
            }
            var selected = false
            DispatchQueue.main.sync {
                selected = self.pickerSessions().contains { $0.id == sessionID }
                if selected { self.setTargetSession(sessionID, announce: true) }
            }
            return selected ? .ok(["selected": sessionID]) : .error(404, "session not selectable.")
        case ("POST", "/__qa/pill/action"):
            guard let action = payload["action"] as? String else {
                return .error(400, "action is required.")
            }
            var accepted = true
            DispatchQueue.main.sync {
                switch action {
                case "close": self.indicator.dismissGrown()
                case "trash":
                    self.replyBubble.onTrashed?()
                    self.replyBubble.hide()
                case "picker":
                    let picker = self.pickerEntries()
                    self.indicator.showPicker(entries: picker.entries, activeName: picker.activeName)
                case "flash":
                    self.indicator.flashMessage("QA receipt", seconds: 30)
                case "collapse":
                    if self.indicator.isGrownVisible { self.indicator.dismissGrown() }
                    else { self.indicator.collapseNow() }
                case "barge_in": self.stopSpeechPlayback()
                case "escape": self.handleVoiceFlowEscape()
                case "annotate_begin": self.annotationOverlay.beginEditing()
                case "user_select":
                    guard let sessionID = payload["session_id"] as? String,
                          self.pickerSessions().contains(where: { $0.id == sessionID }) else {
                        accepted = false
                        return
                    }
                    self.userSelectSession(sessionID)
                case "speaker":
                    guard self.indicator.isGrownVisible else {
                        accepted = false
                        return
                    }
                    self.indicator.qaTapSpeaker()
                default: accepted = false
                }
            }
            return accepted ? .accepted(["action": action]) : .error(400, "unknown pill action.")
        case ("POST", "/__qa/ui/snapshot"):
            var response = LocalAPIResponse.error(500, "ChatPanel snapshot failed.")
            DispatchQueue.main.sync {
                do {
                    let shot = try self.chatPanel.qaSnapshot()
                    response = .ok([
                        "path": shot.path, "width": shot.width, "height": shot.height,
                    ])
                } catch {
                    response = .error(500, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/ui/pill_snapshot"):
            var response = LocalAPIResponse.error(500, "Indicator snapshot failed.")
            DispatchQueue.main.sync {
                do {
                    let name = payload["name"] as? String ?? "state"
                    let shot = try self.indicator.qaSnapshot(name: name)
                    response = .ok([
                        "path": shot.path, "width": shot.width, "height": shot.height,
                    ])
                } catch {
                    response = .error(500, error.localizedDescription)
                }
            }
            return response
        case ("POST", "/__qa/app/terminate"):
            QAEventRecorder.shared.append("app_terminate_requested")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.terminate(nil)
            }
            return .accepted(["terminating": true])
        default:
            return .error(404, "Unknown QA action.")
        }
    }

    private func qaJobs() -> [[String: Any]] {
        ((try? agentJobStore?.jobs(limit: 100)) ?? []).map { job in
            var result: [String: Any] = [
                "id": job.id, "conversation_id": job.conversationID,
                "runtime": job.runtime.rawValue, "trigger": job.trigger.rawValue,
                "state": job.state.rawValue, "prompt": String(job.prompt.prefix(8_000)),
                "enabled": job.isEnabled,
                "updated_at": job.updatedAt.timeIntervalSince1970,
            ]
            if let modelID = job.modelID { result["model_id"] = modelID }
            if let next = job.nextRunAt { result["next_run_at"] = next.timeIntervalSince1970 }
            return result
        }
    }

    private func qaState() -> [String: Any] {
        var state: [String: Any] = [
            "ok": true,
            "config_root": VoiceFlowPaths.shared.configRoot.path,
            "isolated": VoiceFlowPaths.shared.isIsolated,
            "synthetic_input_only": HotkeyManager.qaSyntheticInputIsolationEnabled,
            "jobs": qaJobs(),
            "events": QAEventRecorder.shared.snapshot(after: 0),
        ]
        DispatchQueue.main.sync {
            let conversation = self.agent.currentConversation
            state["assistant"] = [
                "conversation_id": conversation.id,
                "runtime": self.agent.preferredRuntime.rawValue,
                "trust_profile": self.agent.qaTrustProfile.rawValue,
                "activity": self.agent.activity.rawValue,
                "running": self.agent.isRunning,
                "messages": conversation.messages.map { message in
                    [
                        "id": message.id.uuidString,
                        "role": message.role.rawValue,
                        "text": String(AgentSecretPolicy.redacted(message.text).prefix(16_000)),
                    ]
                },
            ] as [String: Any]
            state["ui"] = [
                "panel_visible": self.chatPanel.isVisible,
                "conversation_focus": String(describing: self.chatPanel.conversationFocus),
                "agent_session_rows": self.agentSessionRows().count,
                "job_rows": self.agentJobRows().count,
                "controls": {
                    // The runtime widget lives in the open assistant thread;
                    // with no thread open the harness still asks the model.
                    var controls = self.chatPanel.qaControlState
                    if (controls["runtime_present"] as? Bool) != true {
                        controls["runtime_enabled"] = !self.agent.isRunning
                        controls["runtime_title"] = self.agent.preferredRuntime.label
                    }
                    return controls
                }(),
                "agents_navigation": self.chatPanel.qaAgentsNavigationState,
            ] as [String: Any]
            state["threads"] = self.agentSessionRows().map { row in
                let id = AgentsThreadID(
                    source: row.kind == .assistant ? .assistant : .mcp,
                    value: row.id)
                return [
                    "source": id.source.rawValue,
                    "id": id.value,
                    "title": row.name,
                    "group": AgentsThreadProjection.group(for: AgentsThreadProjectionInput(
                        id: id, title: row.name, owner: row.owner,
                        preview: row.preview, updatedAt: row.updatedAt,
                        unread: row.unread, pendingAsk: row.pendingAsk,
                        live: row.live, archived: row.archived,
                        running: row.running)).label.lowercased(),
                    "unread": row.unread,
                    "pending": row.pendingAsk,
                    "live": row.live,
                    "archived": row.archived,
                    "retained_messages": self.agentThreadDetail(for: id)?.messages.count ?? 0,
                ] as [String: Any]
            }
            state["default_runtime"] = UserSettings.shared.agentBackend
            state["mcp"] = [
                "target_session_id": self.targetSessionId ?? "",
                "sessions": self.mcpServer.sessions.ordered().map { session in
                    [
                        "id": session.id,
                        "number": session.number,
                        "name": session.name ?? "",
                        "engaged": session.engaged,
                        "push_count": self.sessionPushes[session.id]?.count ?? 0,
                        "unread_count": self.sessionPushes[session.id]?.filter { !$0.seen }.count ?? 0,
                    ] as [String: Any]
                },
            ] as [String: Any]
            var pill = self.indicator.qaState
            pill["current_push_session_id"] = self.currentPushSessionId ?? ""
            pill["slots"] = self.slottedSessions().map { session in
                ["number": session.slot, "id": session.id, "label": session.label]
                    as [String: Any]
            }
            pill["pushes"] = self.sessionPushes.map { sessionID, queue in
                [
                    "session_id": sessionID,
                    "count": queue.count,
                    "unread": queue.filter { !$0.seen }.count,
                    "active": queue.filter { $0.done != true }.count,
                ] as [String: Any]
            }
            state["pill"] = pill
            let tts = self.ttsController.status
            state["tts"] = [
                "phase": tts.phase.rawValue,
                "message": tts.message,
                "position": tts.currentTime,
                "duration": tts.duration,
                "has_audio": tts.hasAudio,
                "reply_speaker_active": self.replySpeaker.isActive,
            ] as [String: Any]
            state["annotation_editing"] = self.annotationOverlay.isEditing
            state["automation_editor_visible"] = self.activeAgentJobEditor?.window?.isVisible ?? false
            if let editor = self.activeAgentJobEditor {
                state["automation_editor"] = [
                    "model_accessibility_label": editor.modelCombo.accessibilityLabel() ?? "",
                    "matching_model_ids": editor.qaFilteredModelIDs,
                    "runtime_title": editor.runtimePopUp.titleOfSelectedItem ?? "",
                    "trigger_title": editor.triggerPopUp.titleOfSelectedItem ?? "",
                    "selected_runtime": editor.selectedRuntime.rawValue,
                    "selected_trigger": editor.selectedTrigger.rawValue,
                    "model_enabled": editor.qaModelEnabled,
                    "model_status": editor.qaModelStatus,
                    "model_text": editor.modelCombo.stringValue,
                    "effort_title": editor.effortPopUp.titleOfSelectedItem ?? "",
                    "selected_effort": editor.selectedReasoningEffort ?? "",
                ] as [String: Any]
            }
            state["settings_assistant_visible"] = self.settingsWindow.qaAssistantVisible
            if self.settingsWindow.qaAssistantVisible {
                state["settings_assistant"] = self.settingsWindow.qaAssistantState
            }
            state["capture"] = [
                "state": self.state.rawValue,
                "recording": self.recorder.isRecording,
                "session_active": self.sessionActive,
                "capability": self.activeRunId.flatMap {
                    self.captureRuns[$0]?.capability.rawValue
                } ?? "",
            ] as [String: Any]
            state["clipboard_text"] = String(
                (NSPasteboard.general.string(forType: .string) ?? "").prefix(16_000))
            state["overlays"] = [
                "active_session": self.overlayManager.qaActiveSession,
                "rendered_ids": self.overlayManager.qaRenderedIDs,
                "file_ids": self.overlayManager.list().map(\.id),
                "signature": self.overlayManager.qaSignature,
            ] as [String: Any]
        }
        return state
    }
}
#endif
