import AppKit

extension AppDelegate {
    /// Selection is deliberately unavailable in the daily build until the
    /// preservation/cutover gates pass. QA main.swift validates isolation first.
    var usesT3Environment: Bool {
#if VOICE_FLOW_QA
        return ProcessInfo.processInfo.environment["VOICE_FLOW_NATIVE_SHELL"] == "t3"
#else
        return false
#endif
    }
    func startT3Environment() {
        guard usesT3Environment else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cloud = CloudSyncController.shared
            cloud.nativeEnvironmentEnabled = true
            cloud.onIdentityChanged = { [weak self] in self?.t3Host?.identityChanged() }
            cloud.onNativeHomeWillChange = { [weak self] in await self?.t3Host?.prepareForStop() ?? true }
            cloud.onNativeHomeChangeCancelled = { [weak self] in self?.t3Host?.cancelPreparedStop() }
            cloud.onNativeHomeChanged = { [weak self] in self?.restartT3Environment() }
            restartT3Environment()
        }
    }
    @MainActor
    func restartT3Environment() {
        let previousLaunch = t3LaunchTask
        previousLaunch?.cancel()
        let prior = t3Host
        prior?.invalidate(message: "Reopening the selected environment…")
        let next = T3ApplicationHost(app: self, selectedHome: CloudSyncController.shared.activeNativeHome)
        t3Host = next
        UserSettings.onNativeSettingsWillSave = { [weak next] in
            // Settings controls are main-thread owned. Unexpected off-main
            // mutations are conservatively revoked before any queued UI work.
            if Thread.isMainThread { MainActor.assumeIsolated { next?.settingsChanged() } }
            else { next?.revokeForSettingsMutation() }
        }
        t3LaunchTask = Task { [weak self] in
            // Rapid explicit reconnects must drain the entire predecessor chain.
            await previousLaunch?.value
            if await prior?.stop() == false {
                // Failed draft verification keeps the previous WebView and its
                // original route. Never start a second environment over it.
                if self?.t3Host === next {
                    self?.t3Host = prior
                    UserSettings.onNativeSettingsWillSave = { [weak prior] in
                        if Thread.isMainThread { MainActor.assumeIsolated { prior?.settingsChanged() } }
                        else { prior?.revokeForSettingsMutation() }
                    }
                }
                return
            }
            guard !Task.isCancelled else { await next.stop(); return }
            do { try await next.start() }
            catch {
                await next.stop()
                guard !Task.isCancelled else { return }
                CloudSyncController.shared.nativeEnvironmentStatus = "Local environment unavailable: \(error.localizedDescription) Saved data was retained."
                self?.replyBubble.showTransient("Local environment unavailable. Open Settings for details.", seconds: 8, isError: true)
                self?.showSettings()
            }
        }
    }
    func showT3Environment() {
        guard usesT3Environment else { return }
        Task { @MainActor in
            if let t3Host { t3Host.show() } else { showSettings() }
        }
    }
    /// Reuse native history/speech/settings services without exposing a second
    /// executable Assistant, automation queue or public MCP session registry.
    func configureT3NativeUI() {
        guard usesT3Environment else { return }
        chatPanel.useNativeServicesOnly { [weak self] in self?.showT3Environment() }
        menuBar.onShowChat = { [weak self] in self?.showT3Environment() }
        menuBar.onShowQueue = { [weak self] in self?.showT3Environment() }
        menuBar.claudeSessionsProvider = { [] }
        menuBar.onSelectClaudeSession = nil
        indicator.onClick = { [weak self] in self?.showT3Environment() }
        indicator.onShowQueue = { [weak self] in self?.showT3Environment() }
        indicator.onSessionRemovals = { [] }
        chatPanel.onNewAssistant = nil
        chatPanel.onOpenAssistantSession = nil
    }
}
