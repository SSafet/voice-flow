import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func health(_ connection: OpenCodeConnection, authenticated: Bool) async -> Int? {
    var request = URLRequest(url: connection.baseURL.appendingPathComponent("global/health"))
    request.timeoutInterval = 2
    if authenticated {
        request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
    }
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode
    } catch {
        return nil
    }
}

let supervisor = OpenCodeSupervisor()
let done = DispatchSemaphore(value: 0)
var failure: Error?
Task {
    do {
        async let coldA = supervisor.connection(for: .workspace)
        async let coldB = supervisor.connection(for: .workspace)
        async let coldC = supervisor.connection(for: .workspace)
        let cold = try await [coldA, coldB, coldC]
        let first = cold[0]
        expect(cold.allSatisfy { $0 == first },
               "concurrent cold starts did not coalesce onto one supervised process")
        expect(first.version == "1.17.11", "supervisor accepted an unpinned version")
        let unauthorizedStatus = await health(first, authenticated: false)
        expect(unauthorizedStatus == 401,
               "OpenCode health must reject unauthenticated requests")
        let authorizedStatus = await health(first, authenticated: true)
        expect(authorizedStatus == 200,
               "OpenCode health must accept the process credential")
        let reused = try await supervisor.connection(for: .workspace)
        expect(reused == first, "healthy trust profile must reuse one supervised process")

        let root = VoiceFlowPaths.shared.directory("runtime/opencode/workspace")
        let pidFile = root.appendingPathComponent("process.pid")
        expect(FileManager.default.fileExists(atPath: pidFile.path),
               "supervisor did not record its owned runtime PID")
        for child in ["config", "data", "cache", "state"] {
            expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(child).path),
                   "missing isolated XDG \(child) directory")
        }

        await supervisor.stop(profile: .workspace)
        expect(!FileManager.default.fileExists(atPath: pidFile.path),
               "supervisor left its PID ownership file after stop")
        let stoppedStatus = await health(first, authenticated: true)
        expect(stoppedStatus == nil,
               "stopped runtime still accepts requests")
        let restarted = try await supervisor.connection(for: .workspace)
        expect(restarted.password != first.password,
               "restart must rotate the process credential")
        let restartedStatus = await health(restarted, authenticated: true)
        expect(restartedStatus == 200,
               "restarted runtime did not become healthy")
        await supervisor.stopAll()
        expect(!FileManager.default.fileExists(atPath: pidFile.path),
               "supervisor left its PID ownership file after stopAll")
    } catch {
        failure = error
    }
    done.signal()
}

expect(done.wait(timeout: .now() + 45) == .success, "supervisor live test timed out")
if let failure {
    fputs("FAIL: \(failure.localizedDescription)\n", stderr)
    exit(1)
}
print("opencode supervisor live tests passed")
