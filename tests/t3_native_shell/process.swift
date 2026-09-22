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
        let connected = try await primary.start()
        try expect(connected.environmentId == "fixture-environment", "read environment identity from explicit home")
        try expect(connected.origin.url.absoluteString == "http://127.0.0.1:29471", "read exact owned process origin")
        try expect(connected.credential.count == 64, "generated private credential")
        try expect(!String(describing: connected).contains(connected.credential), "redacted connection description")
        let firstAudit = try audit(primaryHome)
        try expect(firstAudit["argvContainsCredential"] as? Bool == false, "credential absent from argv")
        try expect(firstAudit["ambientOverridePresent"] as? Bool == false, "ambient overrides and provider key absent")
        let originalPID = firstAudit["pid"] as! Int32
        let contender = try make(primaryHome)
        do { _ = try await contender.start(); throw NSError(domain: "unexpected second owner", code: 1) }
        catch T3EnvironmentProcessError.homeInUse { assertions += 1 }
        try expect(kill(originalPID, 0) == 0, "a refused contender leaves owner alive")
        await primary.stop()
        try expect(kill(originalPID, 0) != 0 && errno == ESRCH, "owned child reaped on stop")
        _ = try await contender.start()
        await contender.stop()
        assertions += 1
        let restored = try Data(contentsOf: primaryHome.appendingPathComponent("preserved-source"))
        try expect(restored == preserved, "restart preserves source bytes")

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

        // The resource seal covers every client file, not only index.html's hash.
        try Data("changed".utf8).write(to: runtime.directory.appendingPathComponent("client/app.js"))
        do { _ = try T3BundledEnvironment(bundle: bundle); throw NSError(domain: "tampered client accepted", code: 1) }
        catch T3EnvironmentProcessError.invalidArtifact { assertions += 1 }
        print("ok - \(assertions) signed environment process lifecycle assertions")
    }
}
