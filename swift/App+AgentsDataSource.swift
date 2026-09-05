import Cocoa

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Agents tab data source — the panel's window onto the same per-session
//  push stacks the pill shows. Numbering ≡ the picker (⌃⌥1–6); ghosts and
//  unread state come along unchanged.
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

extension AppDelegate: AgentsDataSource {
    private static let pushTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func agentJobRows() -> [AgentJobRow] {
        let jobs = (try? agentJobStore?.jobs(limit: 100)) ?? []
        return jobs.map { job in
            let assistantName = AssistantsStore.shared.assistant(slug: job.assistantSlug)?.name
                ?? job.assistantSlug
            // The list row prepends the owning assistant itself — repeating
            // the name here rendered "FLORA · Ready · FLORA".
            let preview: String
            if !job.isEnabled {
                preview = "Off · \(job.trigger.rawValue)"
            } else {
                switch job.state {
                case .running:
                    preview = "Running now"
                case .blocked:
                    preview = "Budget or permission blocked"
                case .failed:
                    preview = "Failed"
                case .queued:
                    let next = job.nextRunAt.map(Self.pushTimeFormatter.string(from:)) ?? "soon"
                    preview = "Next \(next)"
                case .completed:
                    preview = job.trigger == .manual
                        ? "Ready"
                        : "Listening · \(job.trigger.rawValue)"
                case .cancelled, .disabled:
                    preview = "Off"
                }
            }
            let runRows = ((try? agentJobStore?.runs(jobID: job.id, limit: 12)) ?? []).map {
                AgentRunRow(
                    id: $0.id, state: $0.state, startedAt: $0.startedAt,
                    finishedAt: $0.finishedAt, attempt: $0.attempt,
                    costUSD: $0.costUSD, error: $0.error)
            }
            return AgentJobRow(
                id: job.id, name: job.name,
                preview: preview,
                time: job.nextRunAt.map(Self.pushTimeFormatter.string(from:))
                    ?? Self.pushTimeFormatter.string(from: job.updatedAt),
                updatedAt: job.updatedAt, assistantName: assistantName,
                assistantSlug: job.assistantSlug,
                state: job.state, isEnabled: job.isEnabled,
                runtime: job.runtime, trigger: job.trigger,
                modelID: job.modelID, prompt: job.prompt,
                nextRunAt: job.nextRunAt, intervalSeconds: job.intervalSeconds,
                dailyTimeMinutes: job.dailyTimeMinutes,
                dailyBudgetUSD: job.dailyBudgetUSD,
                spentTodayUSD: (try? agentJobStore?.spentToday(jobID: job.id)) ?? 0,
                maxDurationSeconds: job.maxDurationSeconds,
                maxAttempts: job.maxAttempts,
                hasPendingTrigger: (try? agentJobStore?.hasPendingTrigger(jobID: job.id)) ?? false,
                runs: runRows, selectedSourceIDs: job.selectedSourceIDs,
                sourceAccessMode: job.sourceAccessMode)
        }
    }

    func agentAutomationModels() -> [OpenRouterModel] {
        OpenRouterModelCatalog.shared.cachedModels(including: agentCatalogFallbackIDs())
    }

    /// The automation picker used to render the cache and stop there, so a
    /// model released after the last refresh was unreachable from this editor.
    func refreshAgentAutomationModels(completion: @escaping ([OpenRouterModel]) -> Void) {
        refreshAgentModelCatalogIfStale { [weak self] result in
            guard let self, let result, !result.models.isEmpty else { return }
            completion(self.agentAutomationModels())
        }
    }

    private func agentCatalogFallbackIDs() -> Set<String> {
        let jobs = (try? agentJobStore?.jobs(limit: 500)) ?? []
        var fallback = Set(jobs.compactMap(\.modelID))
        fallback.insert(UserSettings.shared.agentModel)
        return fallback
    }

    /// Single staleness-gated entry point for every surface that shows models.
    /// `completion` runs on main with the refreshed result, or nil when the
    /// stored snapshot was still fresh and no network call was made.
    func refreshAgentModelCatalogIfStale(
        completion: ((OpenRouterModelCatalogResult?) -> Void)? = nil) {
        let configured = UserSettings.shared.agentBaseURL
        let baseURL = URL(string: configured) ?? URL(string: DefaultAgentBaseURL)!
        let fallbackIDs = agentCatalogFallbackIDs()
        Task {
            let result = await OpenRouterModelCatalog.shared.refreshIfStale(
                baseURL: baseURL,
                apiKey: KeychainStore.shared.loadAgentAPIKey(),
                fallbackIDs: fallbackIDs)
            if let result, result.source == .live {
                vflog("openrouter catalog refreshed: \(result.models.count) models")
            }
            await MainActor.run { completion?(result) }
        }
    }

    func agentAutomationDefaults() -> AgentAutomationDefaults {
        AgentAutomationDefaults(
            runtime: agent.preferredRuntime,
            modelID: UserSettings.shared.agentModel)
    }

    func createAgentAutomation(_ draft: AgentAutomationDraft) throws -> String {
        guard let agentJobStore else {
            throw AgentJobStoreError.invalidState("automations are unavailable")
        }
        guard let assistant = AssistantsStore.shared.assistant(slug: draft.assistantSlug) else {
            throw AgentJobStoreError.invalidState("the selected Assistant is unavailable")
        }
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw AgentJobStoreError.invalidState("instructions cannot be empty")
        }
        if draft.runtime == .opencode || draft.sourceAccessMode == .reviewCopies,
           draft.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw AgentJobStoreError.invalidState("choose an OpenRouter model")
        }
        let now = Date()
        let interval = draft.trigger == .interval
            ? max(60, draft.intervalSeconds ?? 3_600) : nil
        let dailyTime = draft.trigger == .daily
            ? (draft.dailyTimeMinutes ?? 8 * 60) : nil
        let nextRun = AgentJob.nextScheduledRun(
            trigger: draft.trigger, intervalSeconds: interval,
            dailyTimeMinutes: dailyTime, after: now)
        let jobID = UUID().uuidString
        let conversation = agent.createAutomationConversation(
            jobID: jobID, assistant: assistant)
        let job = AgentJob(
            id: jobID, name: draft.name,
            assistantSlug: assistant.slug, conversationID: conversation.id,
            runtime: draft.runtime, trigger: draft.trigger,
            modelID: (draft.runtime == .opencode || draft.sourceAccessMode == .reviewCopies) ? draft.modelID : nil,
            prompt: prompt, trustProfile: .unattended,
            state: draft.enabled ? (nextRun == nil ? .completed : .queued) : .disabled,
            nextRunAt: draft.enabled ? nextRun : nil,
            isEnabled: draft.enabled,
            intervalSeconds: interval,
            dailyTimeMinutes: dailyTime,
            dailyBudgetUSD: min(max(0, draft.dailyBudgetUSD), 10_000),
            maxDurationSeconds: min(max(30, draft.maxDurationSeconds), 14_400),
            maxAttempts: min(max(1, draft.maxAttempts), 10),
            createdAt: now, updatedAt: now, selectedSourceIDs: draft.selectedSourceIDs,
            sourceAccessMode: draft.sourceAccessMode)
        do {
            try agentJobStore.put(job)
            _ = agent.reconcileAutomationReferences(
                try agentJobStore.jobReferencesByConversation())
            chatPanel.refreshAgents()
            return job.id
        } catch {
            if let references = try? agentJobStore.jobReferencesByConversation() {
                _ = agent.reconcileAutomationReferences(references)
                _ = agent.deleteConversation(conversation.id)
            }
            throw error
        }
    }

    func updateAgentAutomation(id: String, draft: AgentAutomationDraft) throws {
        guard let agentJobStore, let current = try agentJobStore.job(id: id) else {
            throw AgentJobStoreError.invalidState("automation no longer exists")
        }
        guard AssistantsStore.shared.assistant(slug: draft.assistantSlug) != nil else {
            throw AgentJobStoreError.invalidState("the selected Assistant is unavailable")
        }
        guard !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentJobStoreError.invalidState("instructions cannot be empty")
        }
        if draft.runtime == .opencode || draft.sourceAccessMode == .reviewCopies,
           draft.modelID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw AgentJobStoreError.invalidState("choose an OpenRouter model")
        }
        let moved = current.assistantSlug != draft.assistantSlug
        if moved {
            try assistantWorkspaceCoordinator.moveConversation(
                id: current.conversationID, to: draft.assistantSlug)
        }
        do {
            try agentJobStore.updateConfiguration(
                jobID: id,
                configuration: AgentJobConfiguration(
                    name: draft.name, assistantSlug: draft.assistantSlug,
                    conversationID: current.conversationID, runtime: draft.runtime,
                    modelID: (draft.runtime == .opencode || draft.sourceAccessMode == .reviewCopies) ? draft.modelID : nil,
                    trigger: draft.trigger, prompt: draft.prompt,
                    trustProfile: current.trustProfile,
                    intervalSeconds: draft.trigger == .interval
                        ? max(60, draft.intervalSeconds ?? 3_600) : nil,
                    dailyTimeMinutes: draft.trigger == .daily
                        ? (draft.dailyTimeMinutes ?? 8 * 60) : nil,
                    concurrencyKey: current.concurrencyKey,
                    dailyBudgetUSD: min(max(0, draft.dailyBudgetUSD), 10_000),
                    maxDurationSeconds: min(max(30, draft.maxDurationSeconds), 14_400),
                    maxAttempts: min(max(1, draft.maxAttempts), 10),
                    selectedSourceIDs: draft.selectedSourceIDs, sourceAccessMode: draft.sourceAccessMode))
        } catch {
            if moved {
                try? assistantWorkspaceCoordinator.moveConversation(
                    id: current.conversationID, to: current.assistantSlug)
            }
            throw error
        }
        _ = agent.reconcileAutomationReferences(
            try agentJobStore.jobReferencesByConversation())
        chatPanel.refreshAgents()
    }

    func duplicateAgentAutomation(id: String) throws -> String {
        guard let source = agentJobRows().first(where: { $0.id == id }) else {
            throw AgentJobStoreError.invalidState("automation no longer exists")
        }
        return try createAgentAutomation(AgentAutomationDraft(
            name: source.name + " Copy", assistantSlug: source.assistantSlug,
            runtime: source.runtime, modelID: source.modelID,
            trigger: source.trigger, prompt: source.prompt,
            intervalSeconds: source.intervalSeconds,
            dailyTimeMinutes: source.dailyTimeMinutes,
            dailyBudgetUSD: source.dailyBudgetUSD,
            maxDurationSeconds: source.maxDurationSeconds,
            maxAttempts: source.maxAttempts, enabled: false,
            selectedSourceIDs: source.selectedSourceIDs, sourceAccessMode: source.sourceAccessMode))
    }

    func deleteAgentAutomation(id: String) throws {
        guard let agentJobStore else {
            throw AgentJobStoreError.invalidState("automations are unavailable")
        }
        try agentJobStore.delete(jobID: id)
        _ = agent.reconcileAutomationReferences(
            try agentJobStore.jobReferencesByConversation())
        chatPanel.refreshAgents()
    }

    func agentAssistantRows() -> [AgentAssistantRow] {
        let definitions = AssistantsStore.shared.assistants
        let jobs = (try? agentJobStore?.jobs(limit: 500)) ?? []
        let conversations = agent?.conversations ?? []
        let baseSlug = AssistantsStore.shared.base?.slug
        return definitions.map { assistant in
            let ownedJobs = jobs.filter { $0.assistantSlug == assistant.slug }
            let ownedConversations = conversations.filter {
                $0.assistantSlug == assistant.slug
                    || ($0.assistantSlug == nil && assistant.slug == baseSlug)
            }
            let latestConversation = ownedConversations.map(\.updatedAt).max()
            let latestJob = ownedJobs.map(\.updatedAt).max()
            let updatedAt = [latestConversation, latestJob].compactMap { $0 }.max()
            return AgentAssistantRow(
                slug: assistant.slug, name: assistant.name,
                description: assistant.description,
                isDefault: assistant.slug == baseSlug,
                conversationCount: ownedConversations.filter {
                    !$0.messages.isEmpty || $0.codexThreadId != nil || $0.turnState != .idle
                }.count,
                automationCount: ownedJobs.count,
                skillCount: assistant.selectedSkills.count,
                attentionCount: ownedJobs.filter {
                    $0.state == .blocked || $0.state == .failed
                }.count + ownedConversations.filter(\.hasUnseenAssistantReply).count,
                running: ownedJobs.contains { $0.state == .running }
                    || ownedConversations.contains { $0.turnState == .running },
                updatedAt: updatedAt)
        }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            if lhs.attentionCount != rhs.attentionCount { return lhs.attentionCount > rhs.attentionCount }
            if lhs.running != rhs.running { return lhs.running }
            if lhs.updatedAt != rhs.updatedAt { return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast) }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // ── System agents (continuity router, speech cleanup, speech) ───────
    // Fixed identities with no Assistant behind them. The store owns model
    // and reasoning; the speech agent's instructions stay in `tts_instructions`
    // so the panel and Settings → Speech never disagree about the voice.

    func agentSystemAgentRows() -> [AgentSystemAgentRow] {
        SystemAgentStore.specs.map { spec in
            let config = SystemAgentStore.shared.config(for: spec.kind)
            let usesTTSInstructions = spec.instructionsSource == .ttsSettings
            let instructions = usesTTSInstructions
                ? UserSettings.shared.ttsInstructions
                : config.instructions
            let instructionsAreDefault = usesTTSInstructions
                ? UserSettings.shared.ttsInstructions == DefaultTTSInstructions
                : config.usesDefaultInstructions
            return AgentSystemAgentRow(
                kind: spec.kind.rawValue,
                name: spec.name,
                purpose: spec.purpose,
                trigger: spec.trigger,
                runsOn: spec.runsOn,
                model: config.model,
                defaultModel: spec.defaultModel,
                effort: config.effort ?? AgentReasoningEffort.unset,
                effortLabel: spec.supportsEffort
                    ? AgentReasoningEffort.label(for: config.effort) : "",
                supportsEffort: spec.supportsEffort,
                instructions: instructions,
                editableInstructions: spec.instructionsSource != .none,
                instructionsNote: usesTTSInstructions
                    ? "Delivery instructions sent with every spoken request (the `tts_instructions` setting). Voice and speed live in Settings → Speech."
                    : nil,
                instructionsContract: spec.instructionsContract,
                usesDefaults: config.usesDefaultModel && config.usesDefaultEffort
                    && instructionsAreDefault)
        }
    }

    func updateAgentSystemAgent(kind: String, model: String, effort: String?,
                                instructions: String?) throws {
        guard let agentKind = SystemAgentKind(rawValue: kind) else {
            throw SystemAgentStoreError.notEditable("Unknown system agent \(kind).")
        }
        let spec = SystemAgentStore.spec(for: agentKind)
        if spec.instructionsSource == .ttsSettings, let instructions {
            let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            UserSettings.shared.ttsInstructions = trimmed.isEmpty
                ? DefaultTTSInstructions : trimmed
            UserSettings.shared.save()
        }
        try SystemAgentStore.shared.save(
            kind: agentKind, model: model, effort: effort,
            instructions: spec.instructionsSource == .store ? instructions : nil)
    }

    func resetAgentSystemAgent(kind: String) throws {
        guard let agentKind = SystemAgentKind(rawValue: kind) else {
            throw SystemAgentStoreError.notEditable("Unknown system agent \(kind).")
        }
        if SystemAgentStore.spec(for: agentKind).instructionsSource == .ttsSettings {
            UserSettings.shared.ttsInstructions = DefaultTTSInstructions
            UserSettings.shared.save()
        }
        try SystemAgentStore.shared.reset(kind: agentKind)
    }

    /// A runtime failure arrives as a whole codex transcript on stderr. The
    /// panel wants the one line that says what went wrong — the usage limit,
    /// the unknown model — not the dump around it.
    private func systemAgentFailureLine(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // The LAST error line, not the first: a codex run prints startup
        // warnings before the one that actually killed it.
        return systemAgentOneLine(
            lines.last { $0.localizedCaseInsensitiveContains("error") } ?? lines.last ?? raw)
    }

    /// One printable line: control characters and ANSI escapes out, runs of
    /// whitespace collapsed, capped so a long answer cannot push the panel's
    /// buttons off screen.
    private func systemAgentOneLine(_ raw: String) -> String {
        let printable = raw.components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(printable.prefix(240))
    }

    /// Exercise the agent's real code path once with whatever is saved, so a
    /// retune can be verified in place instead of by waiting for the next
    /// wake or read-aloud to misbehave.
    func testAgentSystemAgent(kind: String, completion: @escaping (String) -> Void) {
        guard let agentKind = SystemAgentKind(rawValue: kind) else {
            completion("Unknown system agent.")
            return
        }
        let config = SystemAgentStore.shared.config(for: agentKind)
        let finish: (String) -> Void = { text in
            DispatchQueue.main.async { completion(text) }
        }
        switch agentKind {
        case .continuity:
            let sample = AssistantConversation(
                codexThreadId: "system-agent-test",
                title: "Voice Flow panel work",
                messages: [
                    AssistantHistoryMessage(role: .user, text: "Add the system agents to the panel"),
                    AssistantHistoryMessage(role: .assistant, text: "Added them under a SYSTEM section."),
                ])
            Task {
                let started = Date()
                let outcome = await AssistantContinuityClassifier().decide(
                    current: sample, incoming: "Also make the reasoning editable")
                let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
                if outcome.usedFallback {
                    finish("\(config.model) did not answer in \(elapsed) — fell back to reusing the conversation. \(self.systemAgentFailureLine(outcome.reason))")
                } else {
                    finish("\(config.model) · \(AgentReasoningEffort.label(for: config.effort)) → \(outcome.decision == .reuse ? "reuse" : "new") (confidence \(String(format: "%.2f", outcome.confidence))) in \(elapsed). A follow-up should read as reuse.")
                }
            }
        case .speechCleanup:
            Task {
                let started = Date()
                let sample = "Done — see `swift/AgentsView.swift:1042` and https://openrouter.ai/models for the catalog. Commit 9f3ac21 is on main."
                let result = await SpeechCleanupLLM().cleanup(sample)
                let elapsed = String(format: "%.1fs", Date().timeIntervalSince(started))
                if let result {
                    finish("\(config.model) in \(elapsed) → “\(self.systemAgentOneLine(result))”")
                } else {
                    finish("\(config.model) did not return usable text in \(elapsed) — read-aloud would use the deterministic sanitizer instead.")
                }
            }
        case .speech:
            do {
                try ttsController.speak(request: TTSRequest(
                    text: "System agent check. Speech is running on \(config.model).",
                    voice: UserSettings.shared.ttsVoice,
                    speed: UserSettings.shared.ttsSpeed,
                    instructions: UserSettings.shared.ttsInstructions))
                finish("Speaking now with \(config.model) · voice \(UserSettings.shared.ttsVoice). If you hear it, the model is live.")
            } catch {
                finish("\(config.model) could not speak: \(error.localizedDescription)")
            }
        }
    }

    func runAgentJob(_ jobId: String) {
        Task { [weak self] in
            do {
                _ = try await self?.agentSupervisor?.runNow(jobID: jobId)
                await MainActor.run { self?.chatPanel.refreshAgents() }
            } catch {
                await MainActor.run {
                    self?.replyBubble.showTransient("could not run automation", seconds: 5)
                }
            }
        }
    }

    func cancelAgentJob(_ jobId: String) {
        Task { [weak self] in
            do {
                try await self?.agentSupervisor?.stopRun(jobID: jobId)
                await MainActor.run { self?.chatPanel.refreshAgents() }
            } catch {
                await MainActor.run {
                    self?.replyBubble.showTransient("could not stop automation", seconds: 5)
                }
            }
        }
    }

    func setAgentJob(_ jobId: String, enabled: Bool) {
        Task { [weak self] in
            do {
                if enabled { try await self?.agentSupervisor?.enable(jobID: jobId) }
                else { try await self?.agentSupervisor?.disable(jobID: jobId) }
                await MainActor.run { self?.chatPanel.refreshAgents() }
            } catch {
                await MainActor.run {
                    self?.replyBubble.showTransient("could not update automation", seconds: 5)
                }
            }
        }
    }

    func assistantWorkspace(slug: String) throws -> AssistantWorkspaceSnapshot {
        try assistantWorkspaceCoordinator.snapshot(slug: slug)
    }

    func createAgentAssistant(_ draft: AssistantDraft) throws -> String {
        let slug = try assistantWorkspaceCoordinator.createAssistant(draft)
        chatPanel.refreshAgents()
        return slug
    }

    func duplicateAgentAssistant(slug: String, name: String) throws -> String {
        let duplicate = try assistantWorkspaceCoordinator.duplicateAssistant(
            slug: slug, name: name)
        chatPanel.refreshAgents()
        return duplicate
    }

    func updateAgentAssistant(slug: String, draft: AssistantDraft,
                              expectedRevision: String) throws {
        try assistantWorkspaceCoordinator.updateAssistant(
            slug: slug, draft: draft, expectedRevision: expectedRevision)
        replySpeaker.voiceOverride = agent.activeAssistant?.voice
        chatPanel.refreshAgents()
    }

    func updateAgentAssistantMemory(slug: String, kind: String, content: String,
                                    expectedRevision: String) throws -> AgentMemoryDocument {
        let document = try assistantWorkspaceCoordinator.updateMemory(
            slug: slug, kind: kind, content: content,
            expectedRevision: expectedRevision)
        chatPanel.refreshAgents()
        return document
    }

    func createAgentAssistantConversation(slug: String) throws -> String {
        let id = try assistantWorkspaceCoordinator.createConversation(
            assistantSlug: slug)
        chatPanel.refreshAgents()
        return id
    }

    func deleteAgentAssistant(slug: String) throws -> AssistantDeletionOutcome {
        let outcome = try assistantWorkspaceCoordinator.deleteAssistant(slug: slug)
        replySpeaker.voiceOverride = agent.activeAssistant?.voice
        chatPanel.restoreAssistantConversation(agent.currentConversation)
        chatPanel.refreshAgents()
        return outcome
    }

    func agentSessionRows() -> [AgentSessionRow] {
        let activeAssistantConversationId = agent?.currentSessionId
        let assistantNumber = assistantPickerSessionId.flatMap { id in
            slottedSessions().first { $0.id == id }?.slot
        }
        let assistantRows: [AgentSessionRow] = (agent?.conversations ?? [])
            .filter { !$0.messages.isEmpty || $0.codexThreadId != nil || $0.turnState != .idle }
            .map { conversation in
            let isActive = conversation.id == activeAssistantConversationId && assistantPickerEligible
            var preview = conversation.preview
            if preview.count > 120 { preview = String(preview.prefix(120)) + "…" }
            return AgentSessionRow(
                id: conversation.id,
                kind: .assistant,
                number: isActive ? assistantNumber : nil,
                name: conversation.title,
                preview: preview,
                time: Self.pushTimeFormatter.string(from: conversation.updatedAt),
                updatedAt: conversation.updatedAt,
                owner: conversation.assistantNameSnapshot
                    ?? conversation.assistantSlug
                    ?? DefaultAssistantWakeWord,
                unread: conversation.hasUnseenAssistantReply,
                pendingAsk: conversation.turnState == .interrupted,
                live: conversation.turnState == .running,
                running: conversation.turnState == .running,
                archived: conversation.completedAt != nil,
                completed: conversation.completedAt != nil,
                ghost: false)
        }
        // Numbers stay ≡ the pill picker (⌃⌥N identity); the LIST order is
        // latest activity first, per the mock. No-push sessions trail in
        // picker order.
        let picker = pickerSessions().filter { !isAssistantPickerSession($0.id) }
        let pickerIds = Set(picker.map { $0.id })
        // Consumed threads (every push done) have left the pill but stay
        // browsable here until ✓-completed — numberless: they hold no
        // ⌃⌥ slot anymore (ticket #17).
        let history = sessionPushes
            .filter { !pickerIds.contains($0.key) && !$0.value.isEmpty }
            .sorted { ($0.value.last?.at ?? .distantPast) > ($1.value.last?.at ?? .distantPast) }
            .map { (id: $0.key,
                    label: mcpServer.sessions.session($0.key)?.label
                        ?? sessionLabels[$0.key] ?? Self.senderLabel($0.value)) }
        let slotted = slottedSessions().filter { !isAssistantPickerSession($0.id) }
        let slottedIds = Set(slotted.map { $0.id })
        // Eligible but unnumbered = the queue waiting for a freed slot
        // (ticket VF-48: nine sticky numbers, overflow waits).
        let queued = picker.filter { !slottedIds.contains($0.id) }
        let entries: [(id: String, label: String, number: Int?)] =
            slotted.map { ($0.id, $0.label, $0.slot) }
            + queued.map { ($0.id, $0.label, nil) }
            + history.map { ($0.id, $0.label, nil) }
        let rows = entries.map { session -> (row: AgentSessionRow, at: Date?) in
            let queue = sessionPushes[session.id] ?? []
            let newest = queue.last
            var preview = newest.map { $0.text.replacingOccurrences(of: "\n", with: " ") } ?? ""
            if hasPendingAsk(for: session.id),
               let ask = queue.last(where: { $0.isAsk && $0.answer == nil }) {
                preview = "asks: " + ask.text.replacingOccurrences(of: "\n", with: " ")
            }
            // In-progress listening state rides the preview as words, not
            // decorations (ticket VF-48, panel remark #4).
            let activePushes = queue.filter { $0.done != true }
            if let progressIdx = activePushes.lastIndex(where: { $0.resumeSentence != nil }) {
                preview = "paused · \(progressIdx + 1)/\(activePushes.count) — " + preview
            }
            if preview.count > 120 { preview = String(preview.prefix(120)) + "…" }
            let archived = !queue.isEmpty && queue.allSatisfy { $0.done == true }
            let connected = mcpServer.sessions.session(session.id)?.engaged == true
            let listening = inbox.hasWaiter(exactSession: session.id)
            let row = AgentSessionRow(
                id: session.id,
                kind: .mcp,
                number: session.number,
                name: session.label,
                preview: preview,
                time: newest.map { Self.pushTimeFormatter.string(from: $0.at) } ?? "",
                updatedAt: newest?.at ?? .distantPast,
                owner: session.label,
                unread: queue.contains { !$0.seen },
                pendingAsk: hasPendingAsk(for: session.id),
                live: connected || listening,
                running: false,
                archived: archived,
                completed: archived,
                ghost: session.number != nil && mcpServer.sessions.session(session.id) == nil)
            return (row, newest?.at)
        }
        let mcpRows = rows.sorted {
            switch ($0.at, $1.at) {
            case let (a?, b?): return a > b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return ($0.row.number ?? .max) < ($1.row.number ?? .max)
            }
        }.map { $0.row }
        return assistantRows + mcpRows
    }

    func agentThreadDetail(for id: AgentsThreadID) -> AgentThreadDetail? {
        switch id.source {
        case .assistant:
            guard let conversation = agent.conversation(id.value) else { return nil }
            let owner = conversation.assistantNameSnapshot
                ?? conversation.assistantSlug
                ?? DefaultAssistantWakeWord
            let ownerAvailable = conversation.assistantSlug.flatMap {
                AssistantsStore.shared.assistant(slug: $0)
            } != nil || conversation.assistantSlug == nil
            let jobs = (try? agentJobStore?.jobs(conversationID: conversation.id)) ?? []
            let messages = conversation.messages.map { message in
                AgentThreadMessage(
                    id: message.id.uuidString, at: message.at,
                    role: {
                        switch message.role {
                        case .assistant: return .assistant
                        case .user: return .user
                        case .note: return .note
                        }
                    }(),
                    text: message.text, hint: message.attachmentNote)
            }
            let state: String
            if conversation.completedAt != nil { state = "completed" }
            else if conversation.turnState == .running { state = "working" }
            else if conversation.turnState == .interrupted { state = "interrupted" }
            else if conversation.hasUnseenAssistantReply { state = "unread" }
            else { state = "recent" }
            let readOnlyReason: String?
            if !ownerAvailable {
                readOnlyReason = "Assistant unavailable. History remains readable."
            } else if agent.isRunning {
                readOnlyReason = conversation.id == agent.currentSessionId
                    ? "This conversation is working."
                    : "Another conversation is working. Wait for it to finish before replying."
            } else {
                readOnlyReason = nil
            }
            return AgentThreadDetail(
                id: id, title: conversation.title, owner: owner, state: state,
                messages: messages, archived: conversation.completedAt != nil,
                live: conversation.turnState == .running,
                pendingAsk: conversation.turnState == .interrupted,
                canReply: conversation.completedAt == nil && ownerAvailable && !agent.isRunning,
                canSpeak: conversation.latestAssistantReply != nil,
                canComplete: conversation.turnState != .running,
                canDelete: conversation.turnState != .running && jobs.isEmpty,
                claimsContextualFocus: ownerAvailable
                    && conversation.id == agent.currentSessionId
                    && conversation.completedAt == nil,
                readOnlyReason: readOnlyReason,
                linkedAutomationCount: jobs.count,
                runtime: conversation.preferredRuntime
                    ?? AgentRuntimeKind.fromBackendSetting(UserSettings.shared.agentBackend),
                // The composer shows the conversation's own choice; with none,
                // Codex/Claude land on the "Default (<global>)" item, and
                // OpenCode (no default item) shows the resolved model.
                model: {
                    let kind = conversation.preferredRuntime
                        ?? AgentRuntimeKind.fromBackendSetting(UserSettings.shared.agentBackend)
                    if let explicit = conversation.preferredModels?[kind.rawValue] { return explicit }
                    return kind == .opencode ? agent.preferredModel(for: kind, sessionId: conversation.id) : ""
                }(),
                runtimeSwitchable: conversation.turnState != .running && !agent.isRunning,
                activity: conversation.id == agent.currentSessionId ? agent.activity : .idle,
                canSnap: ownerAvailable && conversation.completedAt == nil,
                sourceReviewOnly: (jobs.first(where: { $0.state == .running })?.sourceAccessMode
                    ?? agent.sourceAccessModeForActiveTurn(conversationID: conversation.id)
                    ?? AssistantsStore.shared.assistant(slug: conversation.assistantSlug ?? AssistantsStore.shared.base?.slug ?? "")?.sourceAccessMode
                    ?? .standard) == .reviewCopies)
        case .mcp:
            guard let row = agentSessionRows().first(where: {
                $0.kind == .mcp && $0.id == id.value
            }) else { return nil }
            let queue = sessionPushes[id.value] ?? []
            var messages: [AgentThreadMessage] = []
            for push in queue {
                messages.append(AgentThreadMessage(
                    id: push.id.uuidString, at: push.at, role: .assistant,
                    text: push.text, hint: push.hint))
                if let answer = push.answer, !answer.isEmpty {
                    messages.append(AgentThreadMessage(
                        id: "\(push.id.uuidString):answer", at: push.at,
                        role: .user, text: answer, hint: nil))
                }
            }
            let listening = inbox.hasWaiter(exactSession: id.value)
            let connected = mcpServer.sessions.session(id.value)?.engaged == true
            let state: String
            if row.archived { state = "completed" }
            else if row.pendingAsk { state = "needs your reply" }
            else if row.unread { state = "unread" }
            else if listening { state = "listening" }
            else if connected { state = "connected" }
            else { state = "ended · replies will queue" }
            return AgentThreadDetail(
                id: id, title: row.name, owner: row.owner, state: state,
                messages: messages, archived: row.archived,
                live: listening || connected,
                pendingAsk: row.pendingAsk,
                canReply: !row.archived, canSpeak: !queue.isEmpty,
                canComplete: true, canDelete: true,
                claimsContextualFocus: !row.archived,
                readOnlyReason: nil, linkedAutomationCount: 0)
        }
    }

    @discardableResult
    func activateThread(_ id: AgentsThreadID) -> Bool {
        guard id.source == .assistant else { return true }
        guard let conversation = agent.activateConversation(id.value) else { return false }
        replySpeaker.voiceOverride = agent.activeAssistant?.voice
        chatPanel.restoreAssistantConversation(conversation)
        return true
    }

    func markThreadSeen(_ id: AgentsThreadID) {
        if id.source == .assistant {
            agent.markAssistantRepliesSeen(for: id.value)
        } else if let queue = sessionPushes[id.value] {
            sessionPushes[id.value] = queue.map { push in
                var seen = push
                seen.seen = true
                return seen
            }
        }
        refreshUnreadIndicator()
        chatPanel.refreshTabBadges()
    }

    func hasPendingAsk(for sessionId: String) -> Bool {
        guard let interaction = pendingInteraction else { return false }
        return interaction.sessionId == sessionId && !interaction.resolved
    }

    func sendMessage(toThread id: AgentsThreadID, text: String,
                     attachments: [String] = []) throws {
        switch id.source {
        case .assistant:
            guard let snapshot = agent.conversation(id.value) else {
                throw threadActionError("No longer available")
            }
            guard snapshot.assistantSlug.flatMap({
                AssistantsStore.shared.assistant(slug: $0)
            }) != nil || snapshot.assistantSlug == nil else {
                throw threadActionError("Assistant unavailable. History remains readable.")
            }
            guard !agent.isRunning, let conversation = agent.activateConversation(id.value) else {
                throw threadActionError("Another conversation is working. Wait for it to finish before replying.")
            }
            chatPanel.restoreAssistantConversation(conversation)
            assistantTurnUsesReceiptPresentation = false
            sendToAgent(text: text, includeFreshScreenshot: false,
                        extraImagePaths: attachments)
        case .mcp:
            guard agentThreadDetail(for: id) != nil else {
                throw threadActionError("No longer available")
            }
            if let interaction = pendingInteraction,
               interaction.sessionId == id.value, !interaction.resolved {
                fulfillInteraction(
                    interaction, text: text, includeScreenshot: false,
                    archiveAfterAnswer: false, extraAttachments: attachments)
                return
            }
            inbox.clearUserClosed(id.value)
            reopenStack(id.value)
            let live = inbox.hasWaiter(exactSession: id.value)
            inbox.add(text: text, attachments: attachments, session: id.value)
            if var queue = sessionPushes[id.value], let index = queue.indices.last {
                if queue[index].answer == nil { queue[index].answer = text }
                else { queue[index].answer! += "\n↳ " + text }
                queue[index].seen = true
                queue[index].spoken = true
                queue[index].done = false
                sessionPushes[id.value] = queue
                refreshUnreadIndicator()
            }
            replyBubble.showTransient(
                live ? "sent to \(sessionName(for: id.value))"
                    : "queued for \(sessionName(for: id.value)) — delivered when it reconnects",
                seconds: 5)
        }
    }

    func speakThread(_ id: AgentsThreadID) {
        switch id.source {
        case .assistant:
            guard let text = agent.conversation(id.value)?.latestAssistantReply?.text,
                  !text.isEmpty else { return }
            speakTextThroughPlayer(
                text, source: .assistantReply(title: agentThreadDetail(for: id)?.title ?? "Assistant"),
                showSettingsOnMissingKey: true)
        case .mcp:
            speakSessionUnconsumed(id.value)
        }
    }

    func completeThread(_ id: AgentsThreadID) throws {
        switch id.source {
        case .assistant:
            guard agent.completeConversation(id.value) != nil else {
                throw threadActionError("Wait for this conversation to finish before completing it.")
            }
        case .mcp:
            guard sessionPushes[id.value] != nil else {
                throw threadActionError("No longer available")
            }
            if let interaction = pendingInteraction, interaction.sessionId == id.value {
                interaction.cancelled = true
                interaction.semaphore.signal()
            }
            markStackDone(id.value)
            _ = inbox.removeQueued(exactSession: id.value)
            _ = inbox.terminateWait(exactSession: id.value)
            overlayManager.removeAll(forSession: id.value)
            _ = mcpServer.sessions.close(id.value)
            if targetSessionId == id.value {
                setTargetSession(firstAvailableTarget(excluding: id.value), announce: false)
            }
        }
        refreshSessionIndicator()
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
        replyBubble.showTransient("thread completed", seconds: 4)
    }

    func reopenThread(_ id: AgentsThreadID) throws {
        switch id.source {
        case .assistant:
            guard agent.reopenConversation(id.value) != nil else {
                throw threadActionError("No longer available")
            }
        case .mcp:
            guard sessionPushes[id.value] != nil else {
                throw threadActionError("No longer available")
            }
            // Reopen is a deliberate re-engagement: lift the closed-session
            // marker Complete set, or the agent's next wait_for_message is
            // told the session terminated and queued replies strand.
            inbox.clearUserClosed(id.value)
            reopenStack(id.value)
        }
        refreshSessionIndicator()
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
    }

    func deleteThread(_ id: AgentsThreadID) throws {
        switch id.source {
        case .assistant:
            let jobs = try agentJobStore?.jobs(conversationID: id.value) ?? []
            guard jobs.isEmpty else {
                throw threadActionError(
                    "This conversation is used by \(jobs.count) automation\(jobs.count == 1 ? "" : "s"). Reassign or delete them first.")
            }
            guard agent.deleteConversation(id.value) != nil else {
                throw threadActionError("Wait for this conversation to finish before deleting it.")
            }
            chatPanel.restoreAssistantConversation(agent.currentConversation)
        case .mcp:
            guard sessionPushes[id.value] != nil
                    || mcpServer.sessions.session(id.value) != nil else {
                return
            }
            if let interaction = pendingInteraction, interaction.sessionId == id.value {
                interaction.cancelled = true
                interaction.semaphore.signal()
            }
            if playerContext?.sessionId == id.value { stopSpeechPlayback() }
            sessionPushes.removeValue(forKey: id.value)
            sessionLabels.removeValue(forKey: id.value)
            sessionSlots.removeValue(forKey: id.value)
            _ = inbox.removeQueued(exactSession: id.value)
            _ = inbox.terminateWait(exactSession: id.value)
            overlayManager.removeAll(forSession: id.value)
            _ = mcpServer.sessions.close(id.value)
            if currentPushSessionId == id.value { currentPushSessionId = nil }
            if targetSessionId == id.value {
                setTargetSession(firstAvailableTarget(excluding: id.value), announce: false)
            }
        }
        refreshSessionIndicator()
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
        replyBubble.showTransient("thread deleted", seconds: 4)
    }

    private func threadActionError(_ message: String) -> NSError {
        NSError(domain: "VoiceFlow.Threads", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Read-aloud honors the consumption cursor (ticket #16): only pushes
    /// neither spoken before nor answered are read. Fully caught up? A
    /// press is an explicit request to REPLAY the stack. Playback is a
    /// SENTENCE QUEUE (ticket VF-48): skips are exact, an interrupted push
    /// keeps a resume point, and the cursor advances with the voice —
    /// a push is spoken only once the voice moved past it. Consumption to
    /// done history still lands only when playback ends (ticket #21).
    func speakSessionUnconsumed(_ sessionId: String, allowReplay: Bool = true) {
        guard let queue = sessionPushes[sessionId], !queue.isEmpty else {
            replyBubble.showTransient("nothing to read for this session", seconds: 4)
            return
        }
        // VF-53: scope to what the pill shows (done history excluded) and,
        // once fully caught up, replay only the newest push — listening
        // starts from the latest, never the whole archive from the top.
        let (indices, replay) = PushSpeechSelection.selection(for: queue.map {
            PushSpeechSelection.Item(spoken: $0.spoken == true,
                                     answered: $0.answer != nil,
                                     done: $0.done == true)
        })
        if replay, !allowReplay {
            // Never flashMessage here — it would stomp the grown view the
            // user is looking at (interaction audit C4/C13); showTransient
            // yields to grown content on its own.
            replyBubble.showTransient("all heard — 🔊 replays", seconds: 3)
            return
        }
        // VF-43: speech gets the sanitized form; the stored push text and
        // everything the panel shows stay untouched.
        let sentences = indices.map { SpeechSentencer.sentences(of: SpeechSanitizer.sanitize(queue[$0].text)) }
        let map = PlaybackQueueMap(counts: sentences.map { $0.count })
        guard map.totalChunks > 0 else {
            replyBubble.showTransient("nothing to read for this session", seconds: 4)
            return
        }
        // An interrupted first push resumes where it stopped; a replay
        // starts from the top.
        var startChunk = 0
        if !replay, let resume = queue[indices[0]].resumeSentence,
           resume > 0, resume < map.counts[0] {
            startChunk = resume
        }
        let request = chatPanel.currentTTSRequest().normalized()
        // Whatever batch was still settling settles now — only what was
        // actually heard retires (finalize filters on spoken).
        if playerContext != nil { finalizeSpeechConsumption() }
        do {
            try ttsController.beginQueuedSpeech(
                sentences: sentences.flatMap { $0 },
                voice: request.voice, speed: request.speed,
                instructions: request.instructions, startAt: startChunk)
        } catch TTSError.missingAPIKey {
            replyBubble.showTransient("add an OpenAI API key for speech — opening Settings", seconds: 5)
            showSettings()
            return
        } catch {
            replyBubble.showTransient("couldn't start speech — check the TTS settings", seconds: 5)
            return
        }
        playerContext = PlayerContext(
            source: .sessionStack(id: sessionId, indices: indices),
            sentences: sentences)
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
        refreshPlayerSurface(karaoke: true)
    }

    /// Every read-aloud that isn't a session stack lands here (VF-48
    /// unification): sentence-split the text and run it through the same
    /// queued player, so replies, selections, the Speech drawer and the
    /// HTTP API all get the band/waveform/karaoke/transport sessions have.
    @discardableResult
    func speakTextThroughPlayer(_ text: String, source: PlayerContext.Source,
                                        request baseRequest: TTSRequest? = nil,
                                        showSettingsOnMissingKey: Bool,
                                        preSanitized: Bool = false) -> String? {
        // VF-43: agent-origin text passes through the speech-cleanup step;
        // user-chosen text (selection, Speech drawer, HTTP API) reads
        // verbatim. Heavy content gets one chip-model rewrite attempt with
        // a short timeout; the deterministic sanitizer is the fallback.
        if !preSanitized, case .assistantReply = source,
           UserSettings.shared.speechCleanupLLMEnabled,
           SpeechSanitizer.hasHeavyContent(text) {
            replyBubble.showTransient("preparing speech…", seconds: 2)
            let original = text
            Task { @MainActor [weak self] in
                guard let self else { return }
                let polished = await SpeechCleanupLLM.shared.cleanup(original)
                _ = self.speakTextThroughPlayer(
                    polished ?? SpeechSanitizer.sanitize(original), source: source,
                    request: baseRequest, showSettingsOnMissingKey: showSettingsOnMissingKey,
                    preSanitized: true)
            }
            return nil
        }
        let speakable: String
        if preSanitized {
            speakable = text
        } else if case .text = source {
            speakable = text
        } else {
            speakable = SpeechSanitizer.sanitize(text)
        }
        let sentences = SpeechSentencer.sentences(of: speakable)
        guard !sentences.isEmpty else { return "Nothing to read." }
        var request = baseRequest ?? chatPanel.currentTTSRequest()
        request.text = text
        let normalized = request.normalized()
        chatPanel.applyTTSRequest(normalized)
        if playerContext != nil { finalizeSpeechConsumption() }
        do {
            try ttsController.beginQueuedSpeech(
                sentences: sentences, voice: normalized.voice, speed: normalized.speed,
                instructions: normalized.instructions)
        } catch {
            let message = error.localizedDescription
            chatPanel.setTTSStatus(TTSStatusSnapshot(
                phase: .error, message: message,
                currentTime: 0, duration: 0, hasAudio: false, isCached: false))
            if showSettingsOnMissingKey, let ttsError = error as? TTSError,
               case .missingAPIKey = ttsError {
                replyBubble.showTransient("add an OpenAI API key for speech — opening Settings", seconds: 5)
                showSettings()
            }
            return message
        }
        playerContext = PlayerContext(source: source, sentences: [sentences])
        refreshPlayerSurface(karaoke: true)
        return nil
    }

    /// The assistant's replies play under its own name.
    func assistantPlayerTitle() -> String {
        agent.activeAssistant?.name ?? "Assistant"
    }

    /// Live sources (a streaming reply) grow their queue after the context
    /// is created — mirror the engine's queue into the context. Sentences
    /// only ever append, so a count check is enough.
    private func syncPlayerSentences(_ context: PlayerContext) {
        guard context.sessionId == nil else { return }
        let live = ttsController.queuedSentences
        guard !live.isEmpty, context.sentences.first?.count != live.count else { return }
        context.sentences = [live]
    }

    /// The player band's current state, or nil when no sentence queue is
    /// alive. One shape for every source (VF-48 unification). Main thread.
    private func playerStateSnapshot(compactTitle: Bool) -> FloatingIndicator.PlayerState? {
        guard let context = playerContext,
              ttsController.queuedSpeechActive,
              let chunk = ttsController.queuedChunkIndex else { return nil }
        syncPlayerSentences(context)
        let map = context.map
        let position = map.position(ofChunk: chunk)
        let title: String
        switch context.source {
        case .sessionStack(let id, _):
            let progress = "\(position.item + 1)/\(map.itemCount)"
            let label = sessionLabels[id]
                ?? pickerSessions().first { $0.id == id }?.label
                ?? "session"
            title = compactTitle ? progress : "\(label) · \(progress)"
        case .assistantReply(let name):
            title = name
        case .text(let name):
            title = name
        }
        return FloatingIndicator.PlayerState(
            title: title,
            playing: !ttsController.isPaused,
            envelope: ttsController.audioEnvelope(buckets: 18),
            // The bar reads over the WHOLE queue, same scale the scrubber
            // seeks in — one mental model (Safet QA).
            fraction: (Double(chunk) + 0.5) / Double(max(1, map.totalChunks)),
            speed: ttsController.queuedSpeed ?? UserSettings.shared.ttsSpeed)
    }

    /// One playback surface at a time (ticket VF-48): the grown stack
    /// carries the band while it shows the playing session; otherwise the
    /// one-line strip carries it. Karaoke re-renders only on sentence
    /// boundaries, not on every status tick. Main thread.
    func refreshPlayerSurface(karaoke: Bool = false) {
        // Which grown surface (if any) owns the playing content?
        let onGrownSurface: Bool
        switch playerContext?.source {
        case .sessionStack(let id, _):
            onGrownSurface = indicator.isGrownVisible && currentPushSessionId == id
        case .assistantReply:
            onGrownSurface = indicator.isGrownAssistantConversationVisible
        case .text, .none:
            onGrownSurface = false
        }
        guard let state = playerStateSnapshot(compactTitle: onGrownSurface) else {
            indicator.setGrownPlayer(nil)
            indicator.hidePlayerStrip()
            return
        }
        if onGrownSurface {
            // Karaoke first (it relayouts and restores the dots), the band
            // second (it claims the bottom band back). A still-streaming
            // reply keeps its delta renderer — karaoke starts once the
            // full text landed, so the two never fight for the text view.
            if karaoke, let context = playerContext, !context.streaming,
               let chunk = ttsController.queuedChunkIndex {
                let position = context.map.position(ofChunk: chunk)
                indicator.renderGrownKaraoke(items: context.sentences,
                                             currentItem: position.item,
                                             currentSentence: position.sentence)
            }
            indicator.setGrownPlayer(state)
        } else if indicator.isGrownVisible {
            // Some OTHER view holds the pill while audio plays: the band
            // still renders on it — full title, transport, waveform, no
            // karaoke — so playback is never invisible and uncontrollable
            // (interaction audit C2/C9).
            indicator.setGrownPlayer(state)
        } else {
            indicator.setGrownPlayer(nil)
            indicator.showPlayerStrip(state)
        }
    }

    /// The waveform is the scrubber over the WHOLE queue (Safet QA:
    /// clicking the end must land at the end): a click/drag maps its
    /// fraction onto the full sentence run. Seek unit stays the sentence.
    func playerSeek(messageFraction: Double) {
        guard let context = playerContext else { return }
        syncPlayerSentences(context)
        let total = context.map.totalChunks
        guard total > 0 else { return }
        let target = max(0, min(total - 1, Int(messageFraction * Double(total))))
        ttsController.skipQueuedSpeech(to: target)
    }

    func playerAdjustSpeed(_ delta: Double) {
        let current = ttsController.queuedSpeed ?? UserSettings.shared.ttsSpeed
        let clamped = max(0.25, min(4.0, current + delta))
        ttsController.setQueuedSpeed(clamped)
        // VF-56: the chip is a real setting, not a per-playback tweak — it
        // persists, works with nothing playing, and the Speech drawer +
        // Settings window read it back.
        let settings = UserSettings.shared
        settings.ttsSpeed = clamped
        settings.save()
        var request = chatPanel.currentTTSRequest()
        request.speed = clamped
        chatPanel.applyTTSRequest(request.normalized())
        // Generation runs ahead of playback, so already-fetched sentences
        // would keep the old pace (Safet QA: clicks seemed dead until a
        // skip). Regenerate from the playhead — the change is heard NOW.
        if !ttsController.isPaused, let chunk = ttsController.queuedChunkIndex {
            ttsController.skipQueuedSpeech(to: chunk)
        }
        refreshPlayerSurface()
    }

    // ── The transport key (ticket VF-48) ────────────────
    // Press-count grammar users already know from their earbuds: 1 press =
    // play/pause, 2 = skip forward a sentence, 3 = skip back, hold = stop.
    func transportPressBegan() {
        indicator.collapseNow()
        transportHoldFired = false
        transportHoldTimer?.invalidate()
        transportHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, self.ttsController.queuedSpeechActive else { return }
            self.transportHoldFired = true
            self.transportPressCount = 0
            self.transportResolveTimer?.invalidate()
            self.playerStop()
        }
    }

    func transportPressEnded() {
        transportHoldTimer?.invalidate()
        transportHoldTimer = nil
        guard !transportHoldFired else { return }
        transportPressCount += 1
        transportResolveTimer?.invalidate()
        transportResolveTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { [weak self] _ in
            self?.resolveTransportPresses()
        }
    }

    private func resolveTransportPresses() {
        let count = transportPressCount
        transportPressCount = 0
        guard count > 0 else { return }
        vflog("transport: \(count) press(es), queue active=\(ttsController.queuedSpeechActive)")
        guard ttsController.queuedSpeechActive else {
            // No player alive: a press reads the shown stack or the shown
            // reply, else it keeps the legacy read-selection/stop meaning.
            // A fully-heard stack does NOT replay from here (Safet QA: a
            // press right after a finish restarted the whole thing) — the
            // 🔊 icon and the panel remain the explicit replay paths.
            if indicator.isGrownVisible, let sid = currentPushSessionId {
                speakSessionUnconsumed(sid, allowReplay: false)
            } else if indicator.isGrownAssistantConversationVisible,
                      let reply = lastAssistantReply, !reply.isEmpty {
                speakTextThroughPlayer(reply,
                                       source: .assistantReply(title: assistantPlayerTitle()),
                                       showSettingsOnMissingKey: false)
            } else {
                speakSelectedTextOrStop()
            }
            return
        }
        switch count {
        case 1:
            ttsController.togglePause()
            refreshPlayerSurface()
        case 2:
            playerSkipSentence(1)
        default:
            playerSkipSentence(-1)
        }
    }

    private func playerSkipSentence(_ delta: Int) {
        guard let context = playerContext,
              let chunk = ttsController.queuedChunkIndex else { return }
        syncPlayerSentences(context)
        let target = max(0, min(context.map.totalChunks - 1, chunk + delta))
        vflog("transport: skip \(delta > 0 ? "+" : "")\(delta) — sentence \(chunk) → \(target) of \(context.map.totalChunks)")
        guard target != chunk else { return }
        ttsController.skipQueuedSpeech(to: target)
    }

    /// Hold = stop, the only stop there is: what was heard settles, the
    /// interrupted push keeps its resume point, the strip goes away — and
    /// nothing else happens.
    func playerStop() {
        ttsController.stop()
        indicator.hidePlayerStrip()
        indicator.setGrownPlayer(nil)
        refreshPlayerSurface()
    }

    /// The consumption cursor moves with the voice (ticket VF-48): pushes
    /// fully behind the playhead are spoken (a soft tick marks each
    /// boundary); the one under it keeps a resume point so stopping never
    /// loses the place. Main thread.
    func handlePlayerChunkChange(_ chunk: Int) {
        guard let context = playerContext else { return }
        guard let sid = context.sessionId, let indices = context.sessionIndices,
              var queue = sessionPushes[sid] else {
            // Sources without consumption (reply, selection, drawer) just
            // advance the karaoke and the band.
            refreshPlayerSurface(karaoke: true)
            return
        }
        let position = context.map.position(ofChunk: chunk)
        for (ordinal, index) in indices.enumerated() where queue.indices.contains(index) {
            if ordinal < position.item {
                if queue[index].spoken != true {
                    queue[index].spoken = true
                    if let tick = NSSound(named: "Tink") {
                        tick.volume = 0.2
                        tick.play()
                    }
                }
                queue[index].resumeSentence = nil
            } else if ordinal == position.item {
                queue[index].resumeSentence = position.sentence > 0 ? position.sentence : nil
            }
        }
        sessionPushes[sid] = queue
        chatPanel.refreshAgents()
        refreshPlayerSurface(karaoke: true)
    }

    /// Natural end of the whole stack: everything is heard, the end tone
    /// sounds — and deliberately NOTHING else happens (Safet's call: the
    /// end of a stack is where the user decides what's next). Main thread.
    func handlePlayerQueueFinished() {
        if let context = playerContext, let sid = context.sessionId,
           let indices = context.sessionIndices, var queue = sessionPushes[sid] {
            for index in indices where queue.indices.contains(index) {
                queue[index].spoken = true
                queue[index].resumeSentence = nil
            }
            sessionPushes[sid] = queue
            NSSound(named: "Purr")?.play()
        }
        // Non-session sources end silently — a heard reply or selection
        // needs no receipt. Consumption to done history follows via
        // settleSpeechConsumption on the .ready status this produces.
    }

    /// Fed every TTS status change: once the speech begun by
    /// speakSessionUnconsumed leaves generating/playing — natural finish,
    /// stop, barge-in, or error — its pushes become done history and the
    /// thread leaves the pill's quick surfaces. Main thread.
    func settleSpeechConsumption(_ phase: TTSPlaybackPhase) {
        guard let context = playerContext else { return }
        switch phase {
        case .generating, .playing:
            context.playbackSeen = true
        case .idle, .ready, .error:
            // Ignore transitions from before our request actually started.
            guard context.playbackSeen else { return }
            // A paused player is not finished (ticket VF-48): the sentence
            // queue is still active, just silent — nothing settles yet.
            if ttsController.queuedSpeechActive { return }
            finalizeSpeechConsumption()
        }
    }

    func finalizeSpeechConsumption() {
        guard let context = playerContext else { return }
        playerContext = nil
        // The compact karaoke window opens back up once listening ends —
        // the full text returns, everything marked heard (dimmed).
        let ownedGrown: Bool
        switch context.source {
        case .sessionStack(let id, _):
            ownedGrown = indicator.isGrownVisible && currentPushSessionId == id
        case .assistantReply:
            ownedGrown = indicator.isGrownAssistantConversationVisible
        case .text:
            ownedGrown = false
        }
        if ownedGrown, !context.streaming {
            indicator.renderGrownKaraoke(items: context.sentences,
                                         currentItem: -1, currentSentence: 0)
        }
        // Only session stacks have consumption to settle.
        guard let sid = context.sessionId, let indices = context.sessionIndices,
              var queue = sessionPushes[sid] else { return }
        for index in indices where queue.indices.contains(index) {
            // Only what was actually HEARD retires (ticket VF-48): an
            // interrupted push keeps its resume point and stays active,
            // and a still-unanswered ask stays hot regardless.
            guard queue[index].spoken == true,
                  !(queue[index].isAsk && queue[index].answer == nil) else { continue }
            queue[index].done = true
            queue[index].seen = true
        }
        sessionPushes[sid] = queue
        refreshSessionIndicator()
        refreshUnreadIndicator()
        chatPanel.refreshAgents()
    }
}
