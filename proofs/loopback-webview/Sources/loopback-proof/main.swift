import AppKit
import Foundation
import LoopbackProofCore

func argument(_ name: String, default fallback: String) -> String {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
    return arguments[index + 1]
}

let port = Int(argument("--port", default: "8799")) ?? 8799
let outDirectory = URL(fileURLWithPath: argument("--out", default: FileManager.default.currentDirectoryPath + "/proof-out"))

@MainActor
final class ProofDelegate: NSObject, NSApplicationDelegate {
    let port: Int
    let outDirectory: URL
    let state = ProofState()

    init(port: Int, outDirectory: URL) {
        self.port = port
        self.outDirectory = outDirectory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let server = ProofServer(port: port, state: state)
        let state = self.state
        Task.detached {
            do { try await server.run() } catch { await state.recordServerError("the proof server stopped: \(error)") }
        }
        // Nothing in this program may hang for ever: an agent runs it and reads its
        // exit code.
        Task.detached {
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            FileHandle.standardError.write(Data("the proof did not finish within 180 seconds\n".utf8))
            exit(2)
        }
        Task { await self.runProof() }
    }

    private func runProof() async {
        try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)

        let port = self.port
        let ready = await Task.detached { waitForListeners(port: port, seconds: 10) }.value
        if !ready {
            // Give the server task its moment to report why it could not start.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let why = await state.serverErrorText() ?? "no error was reported"
            let rows = [ProofRow(kind: .check, name: "server_listens", passed: false,
                                 detail: "nothing accepted a connection on 127.0.0.1:\(port) and [::1]:\(port) within 10 seconds (\(why)). "
                                 + "Something may already hold the port: lsof -nP -iTCP:\(port) -sTCP:LISTEN")]
            finish(rows)
            return
        }

        let secret = state.secret
        let rows = await Task.detached { nativeChecks(port: port, secret: secret) }.value
        await state.addAll(rows)
        finish(await state.allRows())
    }

    private func finish(_ rows: [ProofRow]) {
        let table = renderTable(rows, title: "K7 loopback proof — port \(port), \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print(table)
        try? table.write(to: outDirectory.appendingPathComponent("result-table.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(rows) {
            try? data.write(to: outDirectory.appendingPathComponent("result.json"))
        }
        exit(allChecksPassed(rows) ? 0 : 1)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let delegate = ProofDelegate(port: port, outDirectory: outDirectory)
application.delegate = delegate
application.run()
