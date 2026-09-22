import Foundation
import Darwin

private func check(_ value: @autoclosure () -> Bool, _ detail: String) throws {
    if !value() { throw NSError(domain: "T3ProcessTest", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
}

@main struct ProcessTests {
    @MainActor static var managed: [T3EnvironmentProcess] = []
    @MainActor static func main() async throws {
        do { try await run() }
        catch {
            for process in managed { await process.stop() }
            throw error
        }
        for process in managed { await process.stop() }
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let bundle = Bundle(url: root.appendingPathComponent("Fixture.app"))!
        let runtime = try T3BundledEnvironment(bundle: bundle)
        var assertions = 0
        func expect(_ value: @autoclosure () -> Bool, _ detail: String) throws { try check(value(), detail); assertions += 1 }
        func home(_ name: String, mode: String = "ready") throws -> URL {
            let value = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(mode.utf8).write(to: value.appendingPathComponent("fixture-mode"))
            return value
        }
        func make(_ home: URL) throws -> T3EnvironmentProcess {
            let process = try T3EnvironmentProcess(runtime: runtime, home: home, workingDirectory: root, port: 29471)
            managed.append(process)
            return process
        }
        func audit(_ home: URL) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("bootstrap-audit.json"))) as! [String: Any]
        }
        let primaryHome = try home("primary")
        let preserved = Data("saved thread fixture\0🧭".utf8)
        try preserved.write(to: primaryHome.appendingPathComponent("preserved-source"))
        let primary = try make(primaryHome)
        do { _ = try primary.authorityEnvironmentIdentity(); throw NSError(domain: "authority before launch", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }
        let nativeAuthority = T3NativeAuthorityBootstrap(origin: "http://127.0.0.1:12345", credential: String(repeating: "a", count: 43))
        try expect(!primary.revokeRuntimeAuthority(), "no runtime signal before child readiness")
        let unmarkedRuntime = try T3BundledEnvironment(bundle: Bundle(url: root.appendingPathComponent("Unmarked.app"))!)
        let unmarkedHome = root.appendingPathComponent("must-not-create-unmarked-home")
        let unmarked = try T3EnvironmentProcess(runtime: unmarkedRuntime, home: unmarkedHome, workingDirectory: root, port: 29472)
        do { _ = try await unmarked.start(nativeAuthority: nativeAuthority); throw NSError(domain: "unmarked native runtime admitted", code: 1) }
        catch T3EnvironmentProcessError.invalidArtifact { assertions += 1 }
        try expect(!FileManager.default.fileExists(atPath: unmarkedHome.path), "unmarked archive refuses native launch before home creation or process spawn")
        let connected = try await primary.start(nativeAuthority: nativeAuthority)
        let firstIdentity = try primary.authorityEnvironmentIdentity()
        try expect(firstIdentity.environmentID == connected.environmentId, "authority is bound to owned environment identity")
        try expect(connected.environmentId == "fixture-environment", "read environment identity from explicit home")
        try expect(connected.origin.url.absoluteString == "http://127.0.0.1:29471", "read exact owned process origin")
        try expect(connected.credential.count == 64, "generated private credential")
        try expect(!String(describing: connected).contains(connected.credential), "redacted connection description")
        try expect(primary.revokeRuntimeAuthority(), "ready owned native child accepts runtime revocation signal")
        let revokeReceipt = primaryHome.appendingPathComponent("revocation-receipt")
        let revokeDeadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: revokeReceipt.path), Date() < revokeDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try expect(FileManager.default.fileExists(atPath: revokeReceipt.path), "real child receives SIGUSR2 through owned Process")
        let identityAfterRevocation = try primary.authorityEnvironmentIdentity()
        try expect(identityAfterRevocation == firstIdentity, "runtime revocation leaves local history process alive")
        try expect(!primary.revokeRuntimeAuthority(), "runtime revocation is consumed once per launch")
        let firstAudit = try audit(primaryHome)
        try expect(firstAudit["argvContainsCredential"] as? Bool == false, "credential absent from argv")
        try expect(firstAudit["ambientOverridePresent"] as? Bool == false, "ambient overrides and provider key absent")
        try expect(firstAudit["authorityConfigured"] as? Bool == true && firstAudit["authorityShapeValid"] as? Bool == true, "private authority envelope reached only child stdin")
        try expect(firstAudit["authorityInArgv"] as? Bool == false && firstAudit["authorityInEnvironment"] as? Bool == false, "native capability absent from args and environment")
        let identityFile = primaryHome.appendingPathComponent("userdata/environment-id")
        let identityBytes = try Data(contentsOf: identityFile)
        try FileManager.default.removeItem(at: identityFile)
        try FileManager.default.createSymbolicLink(at: identityFile, withDestinationURL: primaryHome.appendingPathComponent("preserved-source"))
        do { _ = try primary.authorityEnvironmentIdentity(); throw NSError(domain: "symlink identity accepted", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }
        try FileManager.default.removeItem(at: identityFile)
        guard mkfifo(identityFile.path, 0o600) == 0 else { throw NSError(domain: "fixture fifo", code: 1) }
        do { _ = try primary.authorityEnvironmentIdentity(); throw NSError(domain: "fifo identity accepted", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }
        try FileManager.default.removeItem(at: identityFile)
        try Data("different-environment\n".utf8).write(to: identityFile)
        do { _ = try primary.authorityEnvironmentIdentity(); throw NSError(domain: "replacement identity accepted", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }
        try identityBytes.write(to: identityFile)
        let lock = primaryHome.appendingPathComponent(".voiceflow-owner.lock")
        let movedLock = primaryHome.appendingPathComponent("original-lock")
        try FileManager.default.moveItem(at: lock, to: movedLock)
        try Data().write(to: lock)
        do { _ = try primary.authorityEnvironmentIdentity(); throw NSError(domain: "replacement lock accepted", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.moveItem(at: movedLock, to: lock)
        let originalPID = firstAudit["pid"] as! Int32
        let contender = try make(primaryHome)
        do { _ = try await contender.start(); throw NSError(domain: "unexpected second owner", code: 1) }
        catch T3EnvironmentProcessError.homeInUse { assertions += 1 }
        try expect(kill(originalPID, 0) == 0, "a refused contender leaves owner alive")
        await primary.stop()
        do { _ = try primary.authorityEnvironmentIdentity(); throw NSError(domain: "authority after stop", code: 1) }
        catch T3NativeAuthorityError.unavailable { assertions += 1 }
        try expect(kill(originalPID, 0) != 0 && errno == ESRCH, "owned child reaped on stop")
        _ = try await contender.start()
        let secondIdentity = try contender.authorityEnvironmentIdentity()
        try expect(secondIdentity.environmentID == firstIdentity.environmentID && secondIdentity.generation != firstIdentity.generation, "restart changes launch generation while preserving environment ID")
        try expect(!contender.revokeRuntimeAuthority(), "ordinary non-native child never receives runtime signal")
        let unconfiguredAudit = try audit(primaryHome)
        try expect(unconfiguredAudit["authorityConfigured"] as? Bool == false, "ordinary launch remains unconfigured")
        await contender.stop()
        assertions += 1
        let restored = try Data(contentsOf: primaryHome.appendingPathComponent("preserved-source"))
        try expect(restored == preserved, "restart preserves source bytes")

        let earlyHome = try home("identity-before-ready", mode: "identity-before-ready")
        let early = try make(earlyHome)
        let earlyStart = Task { try await early.start() }
        var earlyIdentity: T3AuthorityEnvironmentIdentity?
        let earlyDeadline = Date().addingTimeInterval(5)
        while earlyIdentity == nil && Date() < earlyDeadline {
            earlyIdentity = try? early.authorityEnvironmentIdentity()
            if earlyIdentity == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        try expect(!early.revokeRuntimeAuthority(), "pre-ready identity does not permit signal delivery")
        try expect(earlyIdentity?.environmentID == "fixture-environment", "owned identity is available before HTTP readiness")
        try expect(!FileManager.default.fileExists(atPath: earlyHome.appendingPathComponent("userdata/server-runtime.json").path), "authority lookup does not wait for HTTP server runtime state")
        try Data().write(to: earlyHome.appendingPathComponent("continue-startup"))
        _ = try await earlyStart.value
        await early.stop()

        for mode in ["exit", "wrong-origin", "timeout"] {
            let target = try home(mode, mode: mode)
            let managed = try make(target)
            do { _ = try await managed.start(timeout: mode == "timeout" ? 0.2 : 5); throw NSError(domain: "unexpected startup", code: 1) }
            catch T3EnvironmentProcessError.exited(let code) { try expect(mode == "exit" && code == 42, "early exit reported") }
            catch T3EnvironmentProcessError.invalidRuntimeState { try expect(mode == "wrong-origin", "wrong address refused") }
            catch T3EnvironmentProcessError.startupTimedOut { try expect(mode == "timeout", "timeout reported") }
            let pid = try audit(target)["pid"] as! Int32
            try expect(kill(pid, 0) != 0 && errno == ESRCH, "failed startup reaps only its own child")
        }
        let cancelledHome = try home("cancelled", mode: "timeout")
        let cancelled = try make(cancelledHome)
        let task = Task { try await cancelled.start() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: cancelledHome.appendingPathComponent("bootstrap-audit.json").path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; throw NSError(domain: "unexpected cancellation success", code: 1) }
        catch is CancellationError { assertions += 1 }
        let cancelledPID = try audit(cancelledHome)["pid"] as! Int32
        try expect(kill(cancelledPID, 0) != 0 && errno == ESRCH, "cancellation awaits owned child cleanup")

        let occupied = try home("occupied")
        let stateDirectory = occupied.appendingPathComponent("userdata")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "pid": Int(getpid()), "port": 12345, "origin": "http://127.0.0.1:12345"]).write(to: stateDirectory.appendingPathComponent("server-runtime.json"))
        do { _ = try await make(occupied).start(); throw NSError(domain: "unexpected adoption", code: 1) }
        catch T3EnvironmentProcessError.homeInUse { assertions += 1 }
        try expect(!FileManager.default.fileExists(atPath: occupied.appendingPathComponent("bootstrap-audit.json").path), "occupied home refused before launch")
        let corrupt = try home("corrupt")
        try FileManager.default.createDirectory(at: corrupt.appendingPathComponent("userdata"), withIntermediateDirectories: true)
        try Data("incomplete state".utf8).write(to: corrupt.appendingPathComponent("userdata/server-runtime.json"))
        do { _ = try await make(corrupt).start(); throw NSError(domain: "corrupt ownership ignored", code: 1) }
        catch T3EnvironmentProcessError.invalidRuntimeState { assertions += 1 }
        try expect(!FileManager.default.fileExists(atPath: corrupt.appendingPathComponent("bootstrap-audit.json").path), "corrupt ownership is preserved and refused before launch")
        let alias = try home("alias")
        try FileManager.default.createSymbolicLink(at: alias.appendingPathComponent("userdata"), withDestinationURL: stateDirectory)
        do { _ = try await make(alias).start(); throw NSError(domain: "aliased data allowed", code: 1) }
        catch T3EnvironmentProcessError.invalidHome { assertions += 1 }
        do { _ = try make(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3")); throw NSError(domain: "live home allowed", code: 1) }
        catch T3EnvironmentProcessError.invalidHome { assertions += 1 }

        // Foundation normalizes the /private/tmp spelling differently before
        // and after creation. The real packaged server exposed this on restart.
        let firstUseRoot = URL(fileURLWithPath: "/private/tmp/vf-process-first-use-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: firstUseRoot) }
        let firstUse = try make(firstUseRoot.appendingPathComponent("environment"))
        let firstConnection = try await firstUse.start()
        await firstUse.stop()
        let restartedConnection = try await firstUse.start()
        try expect(firstConnection.environmentId == restartedConnection.environmentId, "first-use temporary home restarts after Foundation path normalization")
        await firstUse.stop()

        // The resource seal covers every client file, not only index.html's hash.
        try Data("changed".utf8).write(to: runtime.directory.appendingPathComponent("client/app.js"))
        do { _ = try T3BundledEnvironment(bundle: bundle); throw NSError(domain: "tampered client accepted", code: 1) }
        catch T3EnvironmentProcessError.invalidArtifact { assertions += 1 }
        print("ok - \(assertions) signed environment process lifecycle assertions")
    }
}
