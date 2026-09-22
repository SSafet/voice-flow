import AppKit

/// Installation is explicit: bootstrap owns the approved environment/artifact,
/// then supplies this existing-source adapter and its actions to T3ShellWindow.
/// No window, environment, credential or model request is created here.
@MainActor
extension AppDelegate {
    func configureShellInput(service: CapturedService) throws -> ShellCapturedInput {
        guard shellCapturedInput == nil, service.root == VoiceFlowPaths.shared.configRoot else {
            throw ShellInputFailure.invalid
        }
        let source = ShellCapturedInput(paths: .shared, service: service)
        shellCapturedInput = source
        return source
    }

    func installShellInputWindow(_ window: T3ShellWindow) throws {
        guard let source = shellCapturedInput, window.inputCustody === source.custody,
              shellInputWindow == nil else { throw ShellInputFailure.invalid }
        shellInputWindow = window
    }

    func shellInputActions() -> [ShellCapability: T3ShellWindow.Action] {
        guard shellCapturedInput != nil else { return [:] }
        var actions: [ShellCapability: T3ShellWindow.Action] = [:]
        if recorder != nil, backend != nil, captureStore != nil {
            actions[.dictate] = { [weak self] request in
                guard let self, let destination = request.destination,
                      self.shellInputWindow?.freezeComposerTarget() == destination else { return .init(status: .unavailable) }
                if self.recorder.isBusy {
                    // A web click may stop only its own frozen recording.
                    guard self.recorder.isRecording, let id = self.activeRunId,
                          let run = self.captureRuns[id], case .nativeDraft(let deliveryId) = run.route,
                          self.shellCapturedInput?.custody.destination(deliveryId) == destination,
                          run.capability == .dictate else { return .init(status: .unavailable) }
                    self.stopCapture(expectedCapability: .dictate)
                    return .init(status: .completed)
                }
                return .init(status: self.beginCapture(capability: .dictate, deliveryPolicy: .contextual,
                    handsFree: true, nativeDestination: destination) ? .completed : .unavailable)
            }
        }
        if screenCapture != nil {
            actions[.capture] = { [weak self] request in
                guard let self, let destination = request.destination else { return .init(status: .unavailable) }
                return await self.captureForShell(destination)
            }
        }
        if ttsController != nil {
            actions[.speak] = { [weak self] request in
                guard let self, let text = request.text, !text.isEmpty else { return .init(status: .rejected) }
                let error = self.speakTextThroughPlayer(text, source: .text(title: "Thread"), showSettingsOnMissingKey: false)
                return .init(status: error == nil ? .completed : .unavailable)
            }
            actions[.stopSpeaking] = { [weak self] _ in
                guard let self else { return .init(status: .unavailable) }
                self.stopSpeechPlayback(); return .init(status: .completed)
            }
        }
        actions[.openNativeSettings] = { [weak self] _ in
            guard let self else { return .init(status: .unavailable) }
            self.showSettings(); return .init(status: .completed)
        }
        return actions
    }

    private func captureForShell(_ destination: ShellFrozenTarget) async -> ShellCapabilityReceipt {
        guard let shell = shellInputWindow, let source = shellCapturedInput,
              shell.freezeComposerTarget() == destination else { return .init(status: .unavailable) }
        let id: String
        do { id = try source.custody.reserve(destination) }
        catch { return .init(status: .unavailable) }
        do {
            let display = DisplayTopology.underMouse ?? DisplayTopology.primary
            let raw = try await screenCapture.captureScreen(on: display)
            let reservation = try source.custody.reservation(id)
            guard let shot = CaptureStore.saveShot(raw, on: display, pendingDelivery: reservation) else {
                throw ShellInputFailure.unavailable
            }
            let captureId = try source.attachShot(path: shot.path, deliveryId: id)
            let input = try await source.complete(deliveryId: id, text: "", captureIds: [captureId],
                attachments: [shot.path], capability: .snapshot)
            let receipt = await shell.deliver(input)
            showShellInputReceipt(receipt)
            return .init(status: receipt.status == .accepted ? .completed : .unavailable)
        } catch {
            source.custody.abandonEmpty(id) // A committed marker/source remains on disk even if attachment failed.
            replyBubble.showTransient("Capture retained when saved. Review pending input to recover it.", seconds: 7, isError: true)
            return .init(status: .unavailable)
        }
    }

    func deliverCaptureToShell(_ run: CaptureRun) {
        guard case .nativeDraft(let deliveryId) = run.route,
              shellDeliveriesInFlight.insert(run.id).inserted else { return }
        Task { @MainActor in
            defer { shellDeliveriesInFlight.remove(run.id); pruneFinishedCaptureRuns() }
            do {
                guard let shell = shellInputWindow, let source = shellCapturedInput else { throw ShellInputFailure.unavailable }
                var captureIds: [String] = []
                var attachments: [String] = []
                if case .captured(let path, _) = run.snapshot {
                    captureIds = [try source.attachShot(path: path, deliveryId: deliveryId)]
                    attachments = [path]
                }
                if let summary = run.continuousSummary {
                    await captureStore.whenCommitted()
                    captureIds = try source.attachBundle(summary, deliveryId: deliveryId)
                    attachments = summary.framePaths
                }
                let input = try await source.complete(deliveryId: deliveryId, text: run.transcript ?? "", captureIds: captureIds,
                    attachments: attachments, capability: run.capability)
                let receipt = await shell.deliver(input)
                showShellInputReceipt(receipt)
                captureRuns[run.id]?.phase = receipt.status == .accepted ? .delivered : .failed
                // Only an accepted, fully cleaned custody marker permits deletion.
                if receipt.status == .accepted { PendingAudioStore.remove(runId: run.id) }
            } catch {
                captureRuns[run.id]?.phase = .failed
                replyBubble.showTransient("Input kept on this Mac. Review pending input to recover it.", seconds: 7, isError: true)
            }
            if activeRunId == nil { state = .idle }
        }
    }

    /// Recovery UI invokes this explicitly for a displayed delivery ID. No target
    /// substitution, new ID, automatic launch replay or model send is possible.
    func reconcileShellInput(deliveryId: String, receiptOnly: Bool = false) async -> ShellInputReceipt {
        guard let shell = shellInputWindow, let source = shellCapturedInput else {
            return .init(deliveryId: deliveryId, status: .unavailable)
        }
        do {
            let input: ShellInput
            if let existing = source.custody.input(deliveryId) { input = existing }
            else { input = try await source.recover(deliveryId: deliveryId, receiptOnly: receiptOnly) }
            let receipt = await shell.deliver(input)
            showShellInputReceipt(receipt)
            return receipt
        } catch { return .init(deliveryId: deliveryId, status: .unavailable) }
    }

    private func showShellInputReceipt(_ receipt: ShellInputReceipt) {
        if receipt.status == .accepted {
            replyBubble.showTransient("Added to draft")
        } else {
            replyBubble.showTransient("Input kept on this Mac — original draft was not confirmed.", seconds: 7, isError: true)
        }
    }
}
