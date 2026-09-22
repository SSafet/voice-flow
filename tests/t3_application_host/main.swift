import Foundation

// Standalone persistence/lifecycle proof; no AppKit, browser, credential or GUI.
enum T3EnvironmentProcessError: Error { case invalidHome }
struct CloudAccountSelection: Codable {
    var origin: String; var userID: String?; var deviceID: String?; var signedIn: Bool
    var nativeHome: CloudNativeHomeSelection?
}
struct ProofFailure: Error { let message: String }
@MainActor final class DrainGate {
    var continuation: CheckedContinuation<Void, Never>?
    var events: [String] = []
    func stop() async {
        events.append("revoked")
        await withCheckedContinuation { continuation = $0 }
        events.append("child-exited")
    }
    func release() { continuation?.resume(); continuation = nil }
}
@main struct Proof {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, _ detail: String) throws {
            guard condition else { throw ProofFailure(message: detail) }
            count += 1; print("PASS \(detail)")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vf-t3-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = try T3ApplicationLocation.open(root: root.appendingPathComponent("first"))
        let second = try T3ApplicationLocation.open(root: root.appendingPathComponent("first"))
        try check(location.port == second.port && location.browserStore == second.browserStore, "browser origin and store persist across restart")
        let another = try T3ApplicationLocation.open(root: root.appendingPathComponent("other"))
        try check(location.browserStore != another.browserStore, "separate local homes never share browser identity")
        let bytes = try Data(contentsOf: root.appendingPathComponent("first/native-location.json"))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("first"))
        do { _ = try T3ApplicationLocation.open(root: alias.appendingPathComponent("missing")); throw ProofFailure(message: "symlink accepted") }
        catch is T3EnvironmentProcessError { try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("first/missing").path), "reject symlink ancestor before creating data") }
        try check(try Data(contentsOf: root.appendingPathComponent("first/native-location.json")) == bytes, "refusal preserves location bytes")
        let invalid = root.appendingPathComponent("invalid")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        try Data("{invalid".utf8).write(to: invalid.appendingPathComponent("native-location.json"))
        do { _ = try T3ApplicationLocation.open(root: invalid); throw ProofFailure(message: "corrupt origin reset") }
        catch is DecodingError { try check(true, "corrupt browser origin refuses instead of silently resetting drafts") }
        let selected = CloudNativeHomeSelection(origin: "https://example.invalid", ownerId: "owner-a", deviceId: "device-a", homeId: "home-a", label: "Mac")
        var account = CloudAccountSelection(origin: selected.origin, userID: selected.ownerId, deviceID: selected.deviceId, signedIn: true, nativeHome: selected)
        try check(selected.matches(account), "selected verified owner/device matches")
        account.signedIn = false
        try check(!selected.matches(account), "sign-out removes execution selection authority")
        let restored = try JSONDecoder().decode(CloudAccountSelection.self, from: JSONEncoder().encode(account))
        try check(restored.nativeHome?.storeKey == selected.storeKey, "sign-out retains stable readable local home")
        account.signedIn = true; account.userID = "other"
        try check(!selected.matches(account), "new account cannot silently rebind old local home")
        let newHome = CloudNativeHomeSelection(origin: selected.origin, ownerId: selected.ownerId, deviceId: selected.deviceId, homeId: "other-home", label: "Mac")
        try check(newHome.storeKey != selected.storeKey, "explicit different home has distinct data namespace")
        let activity = T3NativeControlActivity()
        try check(!activity.isActive, "ordinary Escape has no native effect to stop")
        activity.begin(); activity.begin(); activity.end()
        try check(activity.isActive, "concurrent computer effect keeps emergency stop active")
        activity.end()
        try check(!activity.isActive, "completed computer effects release emergency stop scope")
        let gate = DrainGate(), drain = T3ApplicationShutdown()
        let first = Task { await drain.drain { await gate.stop() } }
        while gate.continuation == nil { await Task.yield() }
        let repeated = Task { await drain.drain { gate.events.append("incorrect-second-drain") } }
        first.cancel()
        await Task.yield()
        try check(!drain.finished && gate.events == ["revoked"], "cancelled quit waiter does not release or duplicate child drain")
        // This task must run on MainActor while stop awaits: a semaphore would deadlock.
        let progress = Task { @MainActor in gate.events.append("main-actor-progress"); gate.release() }
        await progress.value; await first.value; await repeated.value
        try check(drain.finished && gate.events == ["revoked", "main-actor-progress", "child-exited"], "coalesced shutdown awaits child exit while MainActor remains live")
        await drain.drain { gate.events.append("incorrect-restart") }
        try check(gate.events.count == 3, "completed quit cannot start a second drain")
        print("\(count) assertions passed")
    }
}
