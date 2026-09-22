import AppKit
import Foundation
import WebKit

/// Actual signed environment and matching web client, with no AppDelegate,
/// account, microphone, screen collector, provider turn or daily data services.
/// The coordinator owns the one GUI pass and terminates this captured process.
@main enum PackagedShellProof {
    struct Input: Decodable { let port: UInt16 }

    @MainActor static func main() {
        do { try QALaunchIsolation.validate() }
        catch { fputs("QA isolation refused. No environment was started.\n", stderr); exit(78) }
        do {
            let bytes = FileHandle.standardInput.readDataToEndOfFile()
            guard bytes.count <= 65_536 else { throw T3ShellError.invalidResponse }
            let input = try JSONDecoder().decode(Input.self, from: bytes)
            guard input.port >= 1024, ![8792, 8793].contains(input.port) else { throw T3ShellError.invalidOrigin }
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICE_FLOW_CONFIG_ROOT"]!).resolvingSymlinksInPath()
            let workspace = root.appendingPathComponent("workspace")
            let rules = root.appendingPathComponent("webkit-content-rules")
            for directory in [workspace, rules] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let owner = try T3EnvironmentProcess(runtime: T3BundledEnvironment(), home: root.appendingPathComponent("environment"), workingDirectory: workspace, port: input.port)
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let controller = PackagedShellController(owner: owner, rules: rules)
            application.delegate = controller
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination.setEventHandler { application.terminate(nil) }
            termination.resume()
            controller.start()
            withExtendedLifetime((controller, termination)) { application.run() }
        } catch {
            fputs("Packaged shell fixture could not initialize.\n", stderr)
            exit(1)
        }
    }
}

@MainActor private final class PackagedShellController: NSObject, NSApplicationDelegate {
    let owner: T3EnvironmentProcess
    let rules: URL
    var host: T3ShellWindow?
    var startup: Task<Void, Never>?
    var terminating = false

    init(owner: T3EnvironmentProcess, rules: URL) { self.owner = owner; self.rules = rules }

    func start() {
        startup = Task { @MainActor in
            do {
                let connection = try await owner.start(timeout: 60)
                try Task.checkCancellation()
                let host = try T3ShellWindow(origin: connection.origin, environmentId: connection.environmentId,
                    dataStore: .nonPersistent(), ruleStoreURL: rules)
                self.host = host
                host.onPhaseChanged = { phase in
                    let name: String
                    switch phase {
                    case .idle: name = "idle"
                    case .authenticating: name = "authenticating"
                    case .loading: name = "loading"
                    case .ready: name = "ready"
                    case .failed: name = "failed"
                    case .closed: name = "closed"
                    }
                    FileHandle.standardOutput.write(Data("{\"phase\":\"\(name)\"}\n".utf8))
                }
                host.show()
                try await host.attach(credential: connection.credential)
            } catch {
                fputs("Packaged shell fixture could not attach.\n", stderr)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        startup?.cancel()
        host?.shutdown()
        Task { @MainActor in
            await startup?.value
            await owner.stop()
            FileHandle.standardOutput.write(Data("{\"shutdown\":\"owned-environment-stopped\"}\n".utf8))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
