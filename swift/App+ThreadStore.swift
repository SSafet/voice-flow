import Cocoa
import GRDB

extension AppDelegate {
    /// No UI consumers, agents, backend or sync service start before this gate.
    func beginThreadStoreLaunch() {
        guard !canonicalStoreReady, !threadStoreRecovering else { return }
        threadStoreRecovering = true
        threadStoreRecoveryWindow?.setBusy(true, message: "Verifying thread history…")
        let root = VoiceFlowPaths.shared.configRoot
        threadStoreRecoveryQueue.async { [weak self] in
            let result = Result { try ThreadStoreLaunch.open(configRoot: root, now: Date()) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.threadStoreRecovering = false
                switch result {
                case .success(.ready(let pool, _)):
                    self.acceptThreadStore(pool)
                case .success(.damaged(let report)):
                    self.threadStoreDamage = report
                    self.threadStoreLaunchError = nil
                    do {
                        let choices = try ThreadStoreRecovery.choices(for: report, configRoot: root)
                        self.threadStoreRecoveryWindow?.close()
                        self.threadStoreRecoveryWindow = ThreadStoreRecoveryWindow(report: report, choices: choices) { [weak self] choice in
                            self?.recoverThreadStore(choice)
                        }
                        self.threadStoreRecoveryWindow?.show()
                        vflog("thread history requires recovery; normal startup is paused")
                    } catch { self.showThreadStoreLaunchFailure(error) }
                case .failure(let error): self.showThreadStoreLaunchFailure(error)
                }
            }
        }
    }

    private func acceptThreadStore(_ pool: DatabasePool) {
        do {
            // Mint during writable startup, never from the read-only QA dump.
            _ = try pool.write { try StoreHome.installationID($0) }
            try ThreadDatabase.install(pool, configRoot: VoiceFlowPaths.shared.configRoot)
            threadStoreDamage = nil
            threadStoreLaunchError = nil
            threadStoreRecoveryWindow?.close()
            threadStoreRecoveryWindow = nil
            finishApplicationLaunch()
        } catch {
            try? pool.close()
            showThreadStoreLaunchFailure(error)
        }
    }

    private func showThreadStoreLaunchFailure(_ error: Error) {
        threadStoreLaunchError = String(describing: error)
        vflog("thread history startup blocked: \(error)")
        threadStoreRecoveryWindow?.close()
        threadStoreRecoveryWindow = ThreadStoreRecoveryWindow(error: String(describing: error)) { [weak self] in
            self?.beginThreadStoreLaunch()
        }
        threadStoreRecoveryWindow?.show()
    }

    func recoverThreadStore(_ choice: ThreadStoreRecovery.Choice) {
        guard !canonicalStoreReady, !threadStoreRecovering, let report = threadStoreDamage else { return }
        if choice == .showInFinder { ThreadStoreRecoveryWindow.revealInFinder(report.setAside); return }
        if choice == .startEmpty {
            let alert = NSAlert()
            alert.messageText = "Start with empty thread history?"
            alert.informativeText = "The damaged database and backups will stay in the configuration folder. Previous threads will not appear in the new history."
            alert.addButton(withTitle: "Start Empty")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        threadStoreRecovering = true
        threadStoreRecoveryWindow?.setBusy(true, message: "Preparing and verifying the replacement…")
        let root = VoiceFlowPaths.shared.configRoot
        threadStoreRecoveryQueue.async { [weak self] in
            let result = Result { try ThreadStoreRecovery.apply(choice, report: report, configRoot: root, now: Date()) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.threadStoreRecovering = false
                switch result {
                case .success(let pool): if let pool { self.acceptThreadStore(pool) }
                case .failure(let error):
                    self.threadStoreLaunchError = String(describing: error)
                    self.threadStoreRecoveryWindow?.setBusy(false, message: "Recovery could not be verified. Your files are kept. \(error)")
                }
            }
        }
    }

#if VOICE_FLOW_QA
    func setupStoreQAControl() {
        guard VoiceFlowPaths.shared.isIsolated else { return }
        if localAPIServer == nil { localAPIServer = LocalAPIServer() }
        do {
            if localAPIServer.qaToken == nil { localAPIServer.qaToken = try QAControlSecurity.installToken() }
            localAPIServer.onQA = { [weak self] method, path, body in
                self?.handleQAControl(method: method, path: path, body: body)
                    ?? .error(503, "App not ready.")
            }
            localAPIServer.start()
        } catch { vflog("QA recovery control disabled: \(error)") }
    }
#endif
}
