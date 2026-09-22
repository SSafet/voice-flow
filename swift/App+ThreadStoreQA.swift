#if VOICE_FLOW_QA
import Cocoa

extension AppDelegate {
    func handleThreadStoreQA(method: String, path: String, payload: [String: Any]) -> LocalAPIResponse {
        guard VoiceFlowPaths.shared.isIsolated else { return .error(403, "An isolated QA root is required.") }
        var response = LocalAPIResponse.error(404, "Unknown thread store QA action.")
        DispatchQueue.main.sync {
            do {
                let root = VoiceFlowPaths.shared.configRoot
                switch (method, path) {
                case ("GET", "/__qa/thread-store"):
                    let pool = self.canonicalStoreReady ? try ThreadDatabase.shared() : nil
                    var result = try ThreadStoreQA.dump(pool: pool, configRoot: root)
                    result["pid"] = ProcessInfo.processInfo.processIdentifier
                    result["state"] = self.canonicalStoreReady ? "ready" : (self.threadStoreRecovering ? "verifying" : "blocked")
                    result["normalStartupComplete"] = self.canonicalStoreReady
                    result["reason"] = self.threadStoreLaunchError ?? self.threadStoreDamage?.reason ?? ""
                    result["sharedPoolAvailable"] = (try? ThreadDatabase.shared()) != nil
                    response = .ok(result)
                case ("POST", "/__qa/thread-store/seed"):
                    guard self.canonicalStoreReady else { response = .error(503, "Recovery is required."); return }
                    try ThreadStoreQA.seed(payload, pool: ThreadDatabase.shared(), paths: VoiceFlowPaths.shared)
                    response = .ok(["ok": true])
                case ("POST", "/__qa/thread-store/backup"):
                    guard self.canonicalStoreReady else { response = .error(503, "Recovery is required."); return }
                    let url = try ThreadStoreHealth.backup(pool: ThreadDatabase.shared(), into: root.appendingPathComponent("backups"), now: Date())
                    response = .ok(["path": url.path])
                case ("POST", "/__qa/thread-store/recover"):
                    guard let action = payload["action"] as? String, ["restore", "repair"].contains(action),
                          self.threadStoreRecoveryWindow?.qaChoose(action) == true else {
                        response = .error(409, "That recovery button is not available."); return
                    }
                    response = .ok(["accepted": true])
                case ("POST", "/__qa/thread-store/snapshot"):
                    guard let window = self.threadStoreRecoveryWindow else { response = .error(409, "No recovery window is open."); return }
                    let url = root.appendingPathComponent("thread-store-recovery.png")
                    try window.qaSnapshot(at: url)
                    response = .ok(["path": url.path])
                default: break
                }
            } catch { response = .error(500, String(describing: error)) }
        }
        return response
    }
}
#endif
