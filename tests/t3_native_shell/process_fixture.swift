import Foundation
import Darwin

// A signed, local process fixture. It performs no networking or model calls.
@main struct Fixture {
    static func main() throws {
        let bytes = FileHandle.standardInput.readDataToEndOfFile()
        guard let boot = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let home = boot["t3Home"] as? String,
              let port = boot["port"] as? Int,
              let token = boot["desktopBootstrapToken"] as? String,
              token.count == 64, boot["mode"] as? String == "desktop",
              boot["host"] as? String == "127.0.0.1",
              boot["noBrowser"] as? Bool == true,
              boot["tailscaleServeEnabled"] as? Bool == false else { exit(65) }
        let root = URL(fileURLWithPath: home)
        let mode = (try? String(contentsOf: root.appendingPathComponent("fixture-mode"), encoding: .utf8)) ?? "ready"
        let authority = boot["atikaNativeAuthority"] as? [String: String]
        let cap = authority?["credential"]
        let audit: [String: Any] = [
            "pid": Int(getpid()), "credentialLength": token.count,
            "argvContainsCredential": CommandLine.arguments.contains(where: { $0.contains(token) }),
            "ambientOverridePresent": ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("T3CODE_") || $0.hasPrefix("VITE_") || $0 == "NODE_OPTIONS" || $0 == "OPENROUTER_API_KEY" }),
            "args": CommandLine.arguments.dropFirst().map { $0 },
            "authorityConfigured": authority != nil,
            "authorityShapeValid": authority == nil || (cap?.count == 43 && authority?["origin"] == "http://127.0.0.1:12345"),
            "authorityInArgv": cap.map { value in CommandLine.arguments.contains(where: { $0.contains(value) }) } ?? false,
            "authorityInEnvironment": cap.map { value in ProcessInfo.processInfo.environment.values.contains(where: { $0.contains(value) }) } ?? false,
        ]
        try JSONSerialization.data(withJSONObject: audit).write(to: root.appendingPathComponent("bootstrap-audit.json"), options: .atomic)
        if mode == "exit" { exit(42) }
        if mode != "timeout" {
            let state = root.appendingPathComponent("userdata")
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data("fixture-environment\n".utf8).write(to: state.appendingPathComponent("environment-id"), options: .atomic)
            if mode == "identity-before-ready" {
                while !FileManager.default.fileExists(atPath: root.appendingPathComponent("continue-startup").path) { Thread.sleep(forTimeInterval: 0.01) }
            }
            let snapshot: [String: Any] = ["version": 1, "pid": Int(getpid()), "port": port, "host": "127.0.0.1", "origin": mode == "wrong-origin" ? "http://example.invalid" : "http://127.0.0.1:\(port)"]
            try JSONSerialization.data(withJSONObject: snapshot).write(to: state.appendingPathComponent("server-runtime.json"), options: .atomic)
        }
        RunLoop.main.run()
    }
}
