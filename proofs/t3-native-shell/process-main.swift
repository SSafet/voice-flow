import Foundation
import Darwin

/// Console-only acceptance of the actual packaged runtime. No AppDelegate,
/// native sources, GUI, provider turn or real account is initialized.
@main struct PackagedEnvironmentProof {
    @MainActor static func main() async {
        do { try QALaunchIsolation.validate() }
        catch { fputs("QA isolation refused. No environment was started.\n", stderr); exit(78) }
        do { try await run() }
        catch { fputs("Packaged environment proof failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        struct Input: Decodable { let port: UInt16 }
        let input = try JSONDecoder().decode(Input.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICE_FLOW_CONFIG_ROOT"]!).resolvingSymlinksInPath()
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runtime = try T3BundledEnvironment()
        let home = root.appendingPathComponent("environment")
        let owner = try T3EnvironmentProcess(runtime: runtime, home: home, workingDirectory: workspace, port: input.port)
        do {
            let first = try await owner.start(timeout: 60)
            try await authenticate(first, runtime: runtime)
            await owner.stop()
            let second = try await owner.start(timeout: 60)
            guard first.environmentId == second.environmentId, first.credential != second.credential else {
                throw T3EnvironmentProcessError.invalidRuntimeState
            }
            try await authenticate(second, runtime: runtime)
            await owner.stop()
            // Fixed fields only: never print tokens, cookies, account data or a pairing URL.
            print("{\"packagedRuntime\":true,\"nativeBootstrap\":true,\"httpCookieAuth\":true,\"matchingWebClient\":true,\"restartIdentityPreserved\":true,\"providerCalls\":0}")
        } catch {
            await owner.stop()
            throw error
        }
    }

    @MainActor static func authenticate(_ connection: T3EnvironmentConnection, runtime: T3BundledEnvironment) async throws {
        let authentication = T3BrowserAuthentication(origin: connection.origin, environmentId: connection.environmentId)
        defer { authentication.shutdown() }
        let authenticated = try await authentication.exchange(credential: connection.credential)
        var cookie: HTTPCookie?
        await authenticated.install { cookie = $0 }
        guard let cookie else { throw T3ShellError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: authentication, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: connection.origin.endpoint("api/auth/session"))
        request.setValue(HTTPCookie.requestHeaderFields(with: [cookie])["Cookie"], forHTTPHeaderField: "Cookie")
        let (bytes, raw) = try await session.data(for: request)
        guard (raw as? HTTPURLResponse)?.statusCode == 200,
              let state = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              state["authenticated"] as? Bool == true else { throw T3ShellError.refusedCredentials }
        request.url = connection.origin.url
        let (client, clientResponse) = try await session.data(for: request)
        let expected = try Data(contentsOf: runtime.directory.appendingPathComponent("client/index.html"))
        guard (clientResponse as? HTTPURLResponse)?.statusCode == 200, client == expected else {
            throw T3ShellError.invalidResponse
        }
    }
}
