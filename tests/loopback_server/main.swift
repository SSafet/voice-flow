import Foundation

// The loopback server's core (06 §3.9), tested without a socket: the port rule,
// the Host and Origin checks and the header secret, the single-use ticket, the
// static-delivery rule with its /api/ exception, the staged files a native
// capability leaves for the composer, and the one mount point L4's two service
// objects and S7's captured-data handlers mount through.
//
// Every name here is the name the build brief fixes; nothing is imported from
// Hummingbird, because this file is compiled by xcrun swiftc against the
// Foundation-only core and run by tests/loopback_server/test.sh.

var failures: [String] = []
var checks = 0

func check(_ what: String, _ condition: Bool, _ detail: String = "") {
    checks += 1
    if !condition { failures.append(detail.isEmpty ? what : "\(what): \(detail)") }
}

func checkEqual<T: Equatable>(_ what: String, _ got: T, _ expected: T) {
    check(what, got == expected, "\(got) is not \(expected)")
}

func finish(_ suite: String) -> Never {
    if failures.isEmpty {
        print("\(suite): \(checks) checks, all pass")
        exit(0)
    }
    for failure in failures {
        FileHandle.standardError.write(Data("not ok - \(failure)\n".utf8))
    }
    FileHandle.standardError.write(Data("\(suite): \(failures.count) of \(checks) checks fail\n".utf8))
    exit(1)
}

// ── 1. The port ─────────────────────────────────────────────────────────────
// 06 §3.9 and ruling C9: the app's port is fixed at 8792 on the name localhost,
// bound on both loopback addresses. A QA run or a test overrides it through the
// environment, exactly as LocalAPIServer already does, so no run of this
// package ever binds the owner's port.

checkEqual("the fixed port is 8792", LoopbackPorts.fixedPort, 8792)
checkEqual("the override key is the one the QA harness already uses",
           LoopbackPorts.qaPortEnvironmentKey, "VOICE_FLOW_QA_PORT")
checkEqual("no environment means the fixed port",
           LoopbackPorts.port(environment: [:]), 8792)
checkEqual("the QA port overrides the fixed port",
           LoopbackPorts.port(environment: ["VOICE_FLOW_QA_PORT": "18793"]), 18793)
check("an override never leaves 8792 in place",
      LoopbackPorts.port(environment: ["VOICE_FLOW_QA_PORT": "18793"]) != 8792)
for bad in ["", "0", "-1", "abc", "8792.0", "70000"] {
    checkEqual("a bad override falls back to 8792 (\(bad.debugDescription))",
               LoopbackPorts.port(environment: ["VOICE_FLOW_QA_PORT": bad]), 8792)
}
checkEqual("the three names localhost may resolve to",
           Set(LoopbackPorts.hostNames), Set(["localhost", "127.0.0.1", "::1"]))

// ── 2. Host, Origin, preflight and the header secret ────────────────────────
// K7 measured the arrangement: no secret is 401, a foreign Origin is 403, a
// wrong Host is 403, and a cross-origin preflight is 403. The interface's origin
// is the name localhost, never 127.0.0.1, because Info.plist can name a host and
// not an address.

let port = 8792
let secret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
let access = LoopbackAccess(port: port, secret: secret, developerOrigin: nil)

checkEqual("the secret rides the header name K7 proved", LoopbackAccess.secretHeaderName,
           "x-loopback-secret")
checkEqual("the interface's origin is http://localhost:<port>",
           access.interfaceOrigin, "http://localhost:8792")
checkEqual("a request to a named host with the secret is allowed",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "localhost:8792",
                                               origin: nil, presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), nil)
checkEqual("127.0.0.1:8792 is an allowed Host",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "127.0.0.1:8792",
                                               origin: nil, presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), nil)
checkEqual("[::1]:8792 is an allowed Host",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "[::1]:8792",
                                               origin: nil, presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), nil)
checkEqual("a foreign Host is refused by name",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "evil.example",
                                               origin: nil, presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), .host)
checkEqual("a missing Host is refused", 
           access.evaluate(LoopbackRequestHead(method: "GET", host: nil,
                                               origin: nil, presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), .host)
checkEqual("a foreign Origin is refused by name",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "localhost:8792",
                                               origin: "http://evil.example",
                                               presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), .origin)
checkEqual("the interface's own Origin is allowed",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "localhost:8792",
                                               origin: "http://localhost:8792",
                                               presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), nil)
checkEqual("a request with no Origin is allowed (native callers)",
           access.evaluate(LoopbackRequestHead(method: "POST", host: "127.0.0.1:8792",
                                               origin: nil, presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), nil)
checkEqual("a cross-origin preflight is refused by name",
           access.evaluate(LoopbackRequestHead(method: "OPTIONS", host: "localhost:8792",
                                               origin: "http://evil.example",
                                               presentedSecret: nil,
                                               requiresSecret: true, isPreflight: true)), .preflight)
checkEqual("the secret is required on a guarded route",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "localhost:8792",
                                               origin: nil, presentedSecret: nil,
                                               requiresSecret: true, isPreflight: false)), .secret)
checkEqual("a wrong secret is refused",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "localhost:8792",
                                               origin: nil, presentedSecret: "wrong",
                                               requiresSecret: true, isPreflight: false)), .secret)
checkEqual("the static files need no secret",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "localhost:8792",
                                               origin: nil, presentedSecret: nil,
                                               requiresSecret: false, isPreflight: false)), nil)
checkEqual("a foreign Host is still refused on a static file",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "evil.example",
                                               origin: nil, presentedSecret: nil,
                                               requiresSecret: false, isPreflight: false)), .host)
checkEqual("no secret is 401", LoopbackAccess.status(for: .secret), 401)
checkEqual("a foreign Host is 403", LoopbackAccess.status(for: .host), 403)
checkEqual("a foreign Origin is 403", LoopbackAccess.status(for: .origin), 403)
checkEqual("a preflight is 403", LoopbackAccess.status(for: .preflight), 403)

// The hidden developer setting adds exactly one origin while it is on, and only
// then (06 §3.9, last paragraph).
let developer = LoopbackAccess(port: port, secret: secret,
                               developerOrigin: "http://localhost:5199")
checkEqual("the developer origin is allowed while the setting is on",
           developer.evaluate(LoopbackRequestHead(method: "GET", host: "localhost:8792",
                                                  origin: "http://localhost:5199",
                                                  presentedSecret: secret,
                                                  requiresSecret: true, isPreflight: false)), nil)
checkEqual("and refused when it is off",
           access.evaluate(LoopbackRequestHead(method: "GET", host: "localhost:8792",
                                               origin: "http://localhost:5199",
                                               presentedSecret: secret,
                                               requiresSecret: true, isPreflight: false)), .origin)

// ── 3. The ticket ───────────────────────────────────────────────────────────
// 06 §3.9: a single-use, short-lived ticket minted with the header secret and
// spent on the socket. A second use of the same ticket cannot open a socket.

var clock = Date(timeIntervalSince1970: 1_760_000_000)
let tickets = LoopbackTicketStore(now: { clock }, lifetime: 60)
let first = tickets.mint()
let second = tickets.mint()
checkEqual("a ticket is 32 random bytes as hex", first.count, 64)
check(first != second, "two tickets are not the same value")
check(tickets.consume(first), "a fresh ticket is accepted once")
check(!tickets.consume(first), "the same ticket is refused the second time")
check(!tickets.consume("nope"), "an unknown ticket is refused")
checkEqual("only the unspent ticket remains spendable", tickets.count, 1)
clock = clock.addingTimeInterval(61)
check(!tickets.consume(second), "a ticket older than its lifetime is refused")

// ── 4. Static delivery and the unknown-path rule ────────────────────────────
// 06 §3.9: the built-in bundle is served from the folder branch 02 names; any
// unknown path returns index.html, except a path under one of the reserved
// non-interface prefixes, which must not answer with the page.

checkEqual("the root is the bundle's index",
           LoopbackStaticRouter.decide(path: "/"), .bundleFile("index.html"))
checkEqual("a bundle file is served as itself",
           LoopbackStaticRouter.decide(path: "/assets/main.js"), .bundleFile("assets/main.js"))
checkEqual("the bridge-check page is a page of the bundle",
           LoopbackStaticRouter.decide(path: "/__bridge-check"), .bundleFile("__bridge-check.html"))
checkEqual("an interface thread route falls back to index.html",
           LoopbackStaticRouter.decide(path: "/t/01J8ZK3F9A0000000000000001"), .indexHTML)
checkEqual("an interface project route falls back to index.html",
           LoopbackStaticRouter.decide(path: "/p/01J8ZK3F9A0000000000000001"), .indexHTML)
checkEqual("an unknown path falls back to index.html",
           LoopbackStaticRouter.decide(path: "/something/else"), .indexHTML)
for reserved in ["/api/nope", "/api/v1/threads/nope", "/turn-tools/mcp", "/internal/tools",
                 "/mcp", "/captured/nope", "/shell-files/zzz", "/__qa/state"] {
    checkEqual("a reserved path is not the page: \(reserved)",
               LoopbackStaticRouter.decide(path: reserved), .notFound)
}

// ── 5. The files a native capability leaves for the composer ────────────────
// K7 finding 3: a page cannot put a header on an <img src>, so /shell-files/<id>
// is addressed by an unguessable value that is valid until the app quits.

let shellFiles = LoopbackShellFiles()
let staged = shellFiles.stage(name: "shot.jpg", kind: "image",
                              data: Data("jpeg-bytes".utf8))
checkEqual("the address prefix is the contract's", LoopbackShellFiles.pathPrefix, "/shell-files/")
checkEqual("the address is the prefix plus the id",
           LoopbackShellFiles.address(staged.id), "/shell-files/\(staged.id)")
checkEqual("the id is 32 random bytes as hex", staged.id.count, 64)
checkEqual("the staged file is found by its id", shellFiles.file(id: staged.id)?.data,
           Data("jpeg-bytes".utf8))
checkEqual("the staged file keeps its name and kind", shellFiles.file(id: staged.id)?.kind, "image")
check(shellFiles.file(id: staged.id) != nil, "the file is still there after being read once")
checkEqual("an unknown id is absent", shellFiles.file(id: "not-a-real-id"), nil)
let other = shellFiles.stage(name: "picked.txt", kind: "file", data: Data("x".utf8))
check(other.id != staged.id, "a second staged file has its own address")
checkEqual("both staged files are held", shellFiles.count, 2)
shellFiles.removeAll()
checkEqual("quitting clears staging", shellFiles.count, 0)
checkEqual("and the old address is then absent", shellFiles.file(id: staged.id), nil)

// ── 6. The one mount point ──────────────────────────────────────────────────
// 06 §3.10: L4's files and terminal service objects and S7's captured-data
// handlers are mounted on the loopback server; the mount point owns the route
// prefixes and hands each request to the one service that owns it.

final class RecordingService: LoopbackService {
    let serviceName: LoopbackServiceName
    private(set) var paths: [String] = []
    init(_ name: LoopbackServiceName) { self.serviceName = name }
    func respond(to request: LoopbackServiceRequest) async -> LoopbackServiceResponse {
        paths.append(request.path)
        return LoopbackServiceResponse(status: 200, contentType: "text/plain",
                                       body: Data(serviceName.rawValue.utf8))
    }
}

let mountPoint = LoopbackMountPoint()
let filesService = RecordingService(.files)
let terminalService = RecordingService(.terminal)
let capturedService = RecordingService(.captured)
mountPoint.mount(filesService)
mountPoint.mount(terminalService)
mountPoint.mount(capturedService)

checkEqual("the files prefixes are the contract's",
           Set(LoopbackMountPoint.prefixes[.files] ?? []),
           Set(["/api/v1/files"]))
checkEqual("the terminal prefixes are the contract's",
           Set(LoopbackMountPoint.prefixes[.terminal] ?? []),
           Set(["/api/v1/terminal", "/api/v1/terminals"]))
checkEqual("the captured prefix is the contract's",
           LoopbackMountPoint.prefixes[.captured], ["/captured"])

for (path, expected) in [("/api/v1/files/roots", LoopbackServiceName.files),
                         ("/api/v1/files/roots/proj/read", .files),
                         ("/api/v1/terminals", .terminal),
                         ("/api/v1/terminal", .terminal),
                         ("/captured/search", .captured),
                         ("/captured/picture", .captured)] {
    checkEqual("\(path) is answered by \(expected.rawValue)",
               mountPoint.service(forPath: path)?.serviceName, expected)
}
checkEqual("an unmounted path is answered by no service",
           mountPoint.service(forPath: "/api/v1/threads/ticket"), nil)
checkEqual("a captured path is not confused with the API prefix",
           mountPoint.service(forPath: "/api/v1/oops")?.serviceName, nil)

let routed = await mountPoint.service(forPath: "/captured/search")!.respond(
    to: LoopbackServiceRequest(method: "POST", path: "/captured/search", query: [:],
                               headers: [:], body: Data()))
checkEqual("the captured service answered", String(data: routed.body, encoding: .utf8), "captured")

finish("loopback_server")
