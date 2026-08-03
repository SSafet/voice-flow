import Foundation

// Core.swift is deliberately out of this compile, so stub its logger the same
// way the other isolated harness tests do.
func vflog(_ message: String) {}

// Live containment validation for VF-59.
//
// This does not hand-write a profile to test against — it asks the shipping
// code (`OpenCodeSupervisor.sandboxPolicy` → `AgentSandbox.launchPrefix`) for
// the exact profile the app launches the runtime under, then runs real escape
// attempts through it. A test that invents its own profile proves nothing about
// what actually ships.

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        failures += 1
    }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("vf-sandbox-live-\(UUID().uuidString)")
let workspace = scratch.appendingPathComponent("workspace")
// "Outside" must be outside EVERY granted root, and TMPDIR is granted (build
// tools and shell heredocs write there), so this cannot live beside the
// workspace or the test would pass for the wrong reason.
let outside = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".vf-sandbox-live-outside-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
defer {
    try? FileManager.default.removeItem(at: scratch)
    try? FileManager.default.removeItem(at: outside)
}

/// A port nobody else holds — a fixed one makes the loopback check fail
/// spuriously when a previous run's listener is still winding down.
func freeLoopbackPort() -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
    _ = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var resolved = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &resolved) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: resolved.sin_port)
}
let loopbackPort = freeLoopbackPort()

// A file outside the grant that must survive every attempt below.
let victim = outside.appendingPathComponent("keepme.txt")
try Data("precious\n".utf8).write(to: victim)
// A secret inside the GRANTED workspace — granting a folder must not grant its
// credentials, which is the case a naive "confine to workspace" design misses.
let secret = workspace.appendingPathComponent(".env")
try Data("API_KEY=super-secret-value\n".utf8).write(to: secret)

AgentSandboxSettings.shared.configure {
    AgentSandboxSnapshot(
        workspaceRoots: [workspace.path],
        dial: AgentCapabilityDial(runCommands: true, reachNetwork: true, controlScreen: false))
}

let policy = OpenCodeSupervisor.sandboxPolicy(profile: .workspace)
let profileURL = scratch.appendingPathComponent("sandbox.sb")
guard let prefix = try AgentSandbox.launchPrefix(policy: policy, profileURL: profileURL) else {
    FileHandle.standardError.write(Data("FAIL: sandbox-exec unavailable\n".utf8))
    exit(1)
}

/// Runs a shell command under the generated profile.
@discardableResult
func sandboxed(_ script: String) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: prefix[0])
    process.arguments = Array(prefix.dropFirst()) + ["/bin/sh", "-c", script]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "launch failed: \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// 1. The granted workspace stays fully usable — containment that breaks normal
//    work would just be the old over-restriction wearing a new mechanism.
let inside = sandboxed("echo ok > \(workspace.path)/inside.txt")
expect(inside.status == 0, "writing inside the granted workspace was blocked: \(inside.output)")
expect(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("inside.txt").path),
       "the file written inside the workspace is missing")

// 2. Direct write outside the grant.
let escape = sandboxed("echo pwned > \(outside.path)/escaped.txt")
expect(escape.status != 0, "a direct write outside the workspace succeeded")

// 3. Deletion outside the grant — the concern that started this ticket.
let removal = sandboxed("rm -rf \(outside.path)")
expect(removal.status != 0, "rm -rf outside the workspace succeeded")
expect(FileManager.default.fileExists(atPath: victim.path),
       "a file outside the granted workspace was destroyed")

// 4. Escape by writing and running code, rather than by running a command —
//    the whole reason permission rules on command text cannot be the boundary.
let script = """
import os, socket, subprocess, pathlib
results = []
try:
    pathlib.Path(\"\(outside.path)/py-escape.txt\").write_text('pwned')
    results.append('WRITE-ESCAPED')
except Exception: results.append('write-contained')
try:
    open(\"\(secret.path)\").read(); results.append('SECRET-READ')
except Exception: results.append('secret-contained')
try:
    r = subprocess.run(['/bin/sh','-c','echo x > \(outside.path)/sub.txt'], capture_output=True)
    results.append('SUBPROC-ESCAPED' if r.returncode == 0 else 'subproc-contained')
except Exception: results.append('subproc-contained')
try:
    socket.create_connection(('1.1.1.1', 443), timeout=5); results.append('EXFIL-OPEN')
except Exception: results.append('exfil-contained')
print(' '.join(results))
"""
let scriptURL = workspace.appendingPathComponent("escape.py")
try Data(script.utf8).write(to: scriptURL)
let generated = sandboxed("/usr/bin/python3 \(scriptURL.path)")
expect(generated.output.contains("write-contained"),
       "a model-written script wrote outside the workspace: \(generated.output)")
expect(generated.output.contains("secret-contained"),
       "a .env inside the granted workspace was readable: \(generated.output)")
expect(generated.output.contains("subproc-contained"),
       "a spawned helper process escaped: \(generated.output)")
expect(generated.output.contains("exfil-contained"),
       "a raw socket reached the internet: \(generated.output)")

// 5. A detached daemon must not outlive the turn with its boundary dropped.
let daemon = sandboxed(
    "(/usr/bin/nohup /bin/sh -c 'sleep 0.3; echo bg > \(outside.path)/bg.txt' >/dev/null 2>&1 &); sleep 1.2")
_ = daemon
expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("bg.txt").path),
       "a detached background process escaped the sandbox")

// 6. Loopback must keep working — the model gateway and tool server depend on
//    it, so containment that blocked it would take the runtime down with it.
let listener = Process()
listener.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
listener.arguments = ["-c", """
import http.server, socketserver, threading, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.send_header('Content-Length','2'); s.end_headers(); s.wfile.write(b'ok')
    def log_message(*a): pass
srv = socketserver.TCPServer(('127.0.0.1', \(loopbackPort)), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(12)
"""]
try? listener.run()
Thread.sleep(forTimeInterval: 1.5)
let loopback = sandboxed("/usr/bin/curl -s --max-time 4 http://127.0.0.1:\(loopbackPort)/")
expect(loopback.output.contains("ok"),
       "loopback is unreachable, which would break the model gateway: \(loopback.output)")
let direct = sandboxed("/usr/bin/curl -s --max-time 6 https://example.com -o /dev/null -w '%{http_code}'")
expect(direct.output.trimmingCharacters(in: .whitespacesAndNewlines) == "000",
       "a direct external request bypassed the proxy: \(direct.output)")
listener.terminate()

// 6b. A server must be able to BIND AND ACCEPT on loopback inside the sandbox.
//     The agent runtime is itself an HTTP server Voice Flow drives, so a
//     profile that permits outbound loopback but not inbound lets it start,
//     bind, then die with a bare "ServeError" — every turn failing with a
//     message that names nothing. Outbound-only checks do not catch this.
let servePort = freeLoopbackPort()
let serveScript = """
import http.server, socketserver, threading, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        s.send_response(200); s.send_header('Content-Length','5'); s.end_headers(); s.wfile.write(b'serve')
    def log_message(*a): pass
srv = socketserver.TCPServer(('127.0.0.1', \(servePort)), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
time.sleep(6)
"""
let serveURL = workspace.appendingPathComponent("serve.py")
try Data(serveScript.utf8).write(to: serveURL)
let server = Process()
server.executableURL = URL(fileURLWithPath: prefix[0])
server.arguments = Array(prefix.dropFirst()) + ["/usr/bin/python3", serveURL.path]
let serverPipe = Pipe()
server.standardOutput = serverPipe
server.standardError = serverPipe
try? server.run()
Thread.sleep(forTimeInterval: 2.0)
let served = sandboxed("/usr/bin/curl -s --max-time 4 http://127.0.0.1:\(servePort)/")
expect(served.output.contains("serve"),
       "a server inside the sandbox could not accept a loopback connection — "
       + "the agent runtime would fail to serve at all")
server.terminate()

// 6c. TLS must still work inside the sandbox.
//     The secret-shape denials collide with the system trust store — the CA
//     bundle at /etc/ssl/cert.pem ends in ".pem", SystemRootCertificates ends
//     in ".keychain". Denying those breaks every HTTPS request the agent makes,
//     and curl reports it as a certificate-verify-location error that points
//     nowhere near the sandbox. Assert the trust store stays readable.
for trustFile in ["/etc/ssl/cert.pem",
                  "/System/Library/Keychains/SystemRootCertificates.keychain"]
where FileManager.default.fileExists(atPath: trustFile) {
    let read = sandboxed("head -c 1 \(trustFile) >/dev/null 2>&1 && echo READABLE")
    expect(read.output.contains("READABLE"),
           "the system trust store at \(trustFile) is unreadable, so every TLS "
           + "handshake inside the sandbox would fail")
}
// And the user's own keychain must NOT be readable.
let loginKeychain = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Keychains").path
if FileManager.default.fileExists(atPath: loginKeychain) {
    let peek = sandboxed("ls \(loginKeychain)/*.keychain-db >/dev/null 2>&1 "
                         + "&& head -c 1 \(loginKeychain)/*.keychain-db >/dev/null 2>&1 && echo LEAKED")
    expect(!peek.output.contains("LEAKED"),
           "the user's login keychain is readable inside the sandbox")
}

// 7. The dial must be enforced by the kernel, not by asking the model.
AgentSandboxSettings.shared.configure {
    AgentSandboxSnapshot(
        workspaceRoots: [workspace.path],
        dial: AgentCapabilityDial(runCommands: false, reachNetwork: false, controlScreen: false))
}
let closedProfile = scratch.appendingPathComponent("closed.sb")
if let closed = try AgentSandbox.launchPrefix(
    policy: OpenCodeSupervisor.sandboxPolicy(profile: .workspace), profileURL: closedProfile) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: closed[0])
    process.arguments = Array(closed.dropFirst()) + ["/bin/echo", "ran"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    expect(!text.contains("ran"),
           "the dial closed commands but a program still executed: \(text)")
}

if failures == 0 {
    print("sandbox containment tests passed (7 escape classes blocked, loopback intact)")
} else {
    FileHandle.standardError.write(Data("\(failures) containment failure(s)\n".utf8))
    exit(1)
}
