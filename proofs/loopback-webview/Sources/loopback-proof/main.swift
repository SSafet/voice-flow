import AppKit
import Foundation
import LoopbackProofCore

func argument(_ name: String, default fallback: String) -> String {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
    return arguments[index + 1]
}

let port = Int(argument("--port", default: "8799")) ?? 8799
let previewPort = Int(argument("--preview-port", default: "8798")) ?? 8798
let outDirectory = URL(fileURLWithPath: argument("--out", default: FileManager.default.currentDirectoryPath + "/proof-out"))

@MainActor
final class ProofDelegate: NSObject, NSApplicationDelegate {
    let port: Int
    let previewPort: Int
    let outDirectory: URL
    let state = ProofState()

    init(port: Int, previewPort: Int, outDirectory: URL) {
        self.port = port
        self.previewPort = previewPort
        self.outDirectory = outDirectory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let server = ProofServer(port: port, state: state)
        let preview = PreviewServer(port: previewPort)
        let state = self.state
        Task.detached {
            do { try await server.run() } catch { await state.recordServerError("the proof server stopped: \(error)") }
        }
        Task.detached {
            do { try await preview.run() } catch { await state.recordServerError("the preview server stopped: \(error)") }
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
        let port = self.port
        let previewPort = self.previewPort
        let ready = await Task.detached {
            waitForListeners(port: port, seconds: 10) && waitForPreviewListener(port: previewPort, seconds: 10)
        }.value
        if !ready {
            // Give the server task its moment to report why it could not start.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let why = await state.serverErrorText() ?? "no error was reported"
            let rows = [ProofRow(kind: .check, name: "server_listens", passed: false,
                                 detail: "nothing accepted a connection on 127.0.0.1:\(port), [::1]:\(port) and 127.0.0.1:\(previewPort) "
                                 + "within 10 seconds (\(why)). Something may already hold a port: "
                                 + "lsof -nP -iTCP:\(port) -sTCP:LISTEN")]
            finish(rows)
            return
        }

        // Something answered, which is not the same as this proof's own server
        // answering: another process may hold the port. A listener that recorded a
        // failure makes the run a failure, never a footnote under a pass.
        if let why = await state.serverErrorText() {
            finish([ProofRow(kind: .check, name: "server_listens", passed: false,
                             detail: "a listener of this proof stopped although \(port) answered: \(why). "
                             + "Something else may hold the port: lsof -nP -iTCP:\(port) -sTCP:LISTEN")])
            return
        }

        let secret = state.secret
        var rows = await Task.detached { nativeChecks(port: port, secret: secret) }.value

        let probe = WebViewProbe(port: port, previewPort: previewPort, state: state)
        let ruleListStore = outDirectory.appendingPathComponent("rule-list-store", isDirectory: true)
        try? FileManager.default.createDirectory(at: ruleListStore, withIntermediateDirectories: true)
        rows += await probe.run(
            storeDirectory: ruleListStore,
            snapshotPath: outDirectory.appendingPathComponent("page.png")
        )

        await state.addAll(rows)
        finish(await state.allRows())
    }

    private var tableTitle: String {
        "K7 loopback proof — port \(port), \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    private func finish(_ rows: [ProofRow]) {
        var rows = rows
        if let problem = writeEvidence(rows) {
            rows.append(ProofRow(kind: .check, name: "evidence_written", passed: false, detail: problem))
        }
        print(renderTable(rows, title: tableTitle))
        exit(allChecksPassed(rows) ? 0 : 1)
    }

    /// Writes the two files this run is judged by, and says why when it could not.
    /// A silent failure here would leave an earlier run's files in place and a
    /// later task would copy them into the repository as this run's evidence, so
    /// the reason becomes a failed check and the exit status carries it.
    private func writeEvidence(_ rows: [ProofRow]) -> String? {
        do {
            try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
            try renderTable(rows, title: tableTitle)
                .write(to: outDirectory.appendingPathComponent("result-table.txt"), atomically: true, encoding: .utf8)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: outDirectory.appendingPathComponent("result.json"))
            return nil
        } catch {
            return "the evidence of this run could not be written into \(outDirectory.path): \(error)"
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let delegate = ProofDelegate(port: port, previewPort: previewPort, outDirectory: outDirectory)
application.delegate = delegate
application.run()
