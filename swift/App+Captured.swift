import Foundation

extension AppDelegate {
    /// Collection stays native; the derived search index has no thread-store
    /// ownership and can be rebuilt without changing the source archives.
    func setupCapturedDataIndex() {
        guard let service = CapturedService.shared else {
            let detail = CapturedService.startupError ?? "The index could not be opened."
            vflog("captured index unavailable: \(detail)")
            agent?.note("Captured-data search is unavailable: \(detail)")
            return
        }
        workflowWatcher.addCommittedObserver { [weak service] stream, fields, date in
            service?.observe(stream: stream, fields: fields, at: date)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = LegacyDictationRecovery.run(root: VoiceFlowPaths.shared.configRoot)
            service.start()
            guard !result.failures.isEmpty else { return }
            let detail = result.failures.joined(separator: "\n")
            vflog("dictation recovery incomplete: \(detail)")
            DispatchQueue.main.async { [weak self] in
                self?.agent?.note("Some older dictations could not be recovered: \(detail)")
            }
        }
    }
}
