import AppKit
import Foundation
import WebKit

/// Build-only by default. The root coordinator owns the matching T3 server,
/// bootstrap credential, one UI verification pass and this process's shutdown.
@main
enum T3ShellFixture {
    struct Input: Decodable {
        let origin: URL
        let environmentId: String
        let credential: String
    }

    @MainActor
    static func main() {
        // FIRST executable action, before AppKit, logs, paths or stdin. The same
        // binary must refuse envless LaunchServices relaunch with exit 78.
        do { try QALaunchIsolation.validate() }
        catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(78)
        }

        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 65_536 else { throw T3ShellError.invalidResponse }
            let input = try JSONDecoder().decode(Input.self, from: data)
            let origin = try T3ShellOrigin(input.origin)
            guard origin.scheme == "http", ["127.0.0.1", "localhost"].contains(origin.host),
                  (1024...65535).contains(origin.port), ![8792, 8793].contains(origin.port) else {
                throw T3ShellError.invalidOrigin
            }
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VOICE_FLOW_CONFIG_ROOT"]!, isDirectory: true)
            let rules = root.appendingPathComponent("webkit-content-rules", isDirectory: true)
            try FileManager.default.createDirectory(at: rules, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let application = NSApplication.shared
            application.setActivationPolicy(.regular)
            let host = try T3ShellWindow(origin: origin, environmentId: input.environmentId,
                                         dataStore: .nonPersistent(), ruleStoreURL: rules)
            host.onPhaseChanged = { phase in
                // Fixed state labels only. Never print credentials, payloads or URLs.
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
            signal(SIGTERM, SIG_IGN)
            let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination.setEventHandler {
                host.shutdown()
                application.terminate(nil)
            }
            termination.resume()
            Task { @MainActor in
                host.show()
                do { try await host.attach(credential: input.credential) }
                catch { FileHandle.standardError.write(Data("T3 shell fixture could not attach.\n".utf8)) }
            }
            withExtendedLifetime((host, termination)) { application.run() }
            host.shutdown()
        } catch {
            FileHandle.standardError.write(Data("T3 shell fixture requires a valid isolated loopback attachment.\n".utf8))
            exit(64)
        }
    }
}
