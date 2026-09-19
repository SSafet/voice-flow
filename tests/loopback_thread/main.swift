import Foundation

// The thread protocol's carrier on the loopback server (01 §3.4, 06 §3.9): the
// three routes under /api/v1/threads/, JSON-RPC 2.0 framing, the version
// negotiation, the one-shot carrier's two refusals, and the one error shape with
// the contract's codes as JSON-RPC error -32000 and data {code, message,
// retryable}. The methods themselves are the turn engine's and are registered
// here as handlers, so this suite tests the carrier and not the engine.

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

struct Reply {
    let id: Any?
    let result: Any?
    let error: [String: Any]?
    func data() -> [String: Any] { (error?["data"] as? [String: Any]) ?? [:] }
    func code() -> String { data()["code"] as? String ?? "" }
}

func parse(_ data: Data) -> Reply {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return Reply(id: nil, result: nil, error: ["message": "not a JSON object"])
    }
    return Reply(id: object["id"], result: object["result"],
                 error: object["error"] as? [String: Any])
}

func body(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

let carrier = ThreadRpcCarrier(homeId: "mac-home-1", serverKind: "mac",
                               tickets: LoopbackTicketStore())

checkEqual("the protocol version the contract fixes", ThreadRpcCarrier.protocolVersion, 2)
checkEqual("the oldest version this server accepts", ThreadRpcCarrier.minSupportedVersion, 2)
checkEqual("the WebSocket subprotocol name", ThreadRpcCarrier.subprotocol, "atika.threads.v2")
checkEqual("the two methods the one-shot carrier refuses",
           Set(ThreadRpcCarrier.carrierOnlyRefused), Set(["thread/open", "thread/close"]))

// A handler that answers the way the engine will: a JSON result value.
carrier.register("index/list") { _ in body(["threads": [], "homes": [], "projects": [], "personas": []]) }
carrier.register("index/search") { call in
    let query = call.params["query"] as? String ?? ""
    return body([["threadId": "th-1", "itemId": "it-1", "snippet": query]])
}
carrier.register("thread/send") { call in
    let threadId = call.threadId ?? "none"
    return body(["turn": ["id": "turn-1", "threadId": threadId, "status": "queued"]])
}
carrier.register("boom/notFound") { _ in throw ThreadRpcError.notFound("no such thread") }
carrier.register("boom/secret") { _ in
    throw NSError(domain: "probe", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "token=sk-secret-value-that-must-not-leak"])
}

// ── 1. initialize and version negotiation ───────────────────────────────────
do {
    let connection = ThreadRpcSocketConnection()
    let reply = parse(await carrier.handle(body([
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": ["protocolVersion": 2,
                   "client": ["kind": "mac", "label": "window", "version": "1"]],
    ]), connection: connection))
    let result = reply.result as? [String: Any]
    checkEqual("initialize answers the protocol version", result?["protocolVersion"] as? Int, 2)
    checkEqual("initialize answers the server's kind",
               (result?["server"] as? [String: Any])?["kind"] as? String, "mac")
    checkEqual("initialize answers the home id",
               (result?["server"] as? [String: Any])?["homeId"] as? String, "mac-home-1")
    check("initialize marks the connection initialized", connection.initialized)
}
do {
    let reply = parse(await carrier.handle(body([
        "jsonrpc": "2.0", "id": 2, "method": "initialize",
        "params": ["protocolVersion": 1,
                   "client": ["kind": "browser", "label": "x", "version": "1"]],
    ]), connection: ThreadRpcSocketConnection()))
    checkEqual("an older client is refused with the numeric code", reply.error?["code"] as? Int, -32000)
    checkEqual("the refusal names the code", reply.code(), "unsupported_version")
    checkEqual("the refusal names the client's version", reply.data()["clientVersion"] as? Int, 1)
    checkEqual("the refusal names the server's version", reply.data()["serverVersion"] as? Int, 2)
    checkEqual("the refusal names the oldest supported version", reply.data()["minSupported"] as? Int, 2)
    checkEqual("the refusal is not retryable", reply.data()["retryable"] as? Bool, false)
}

// ── 2. A request without an id, and malformed messages ──────────────────────
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "method": "ping"]), connection: nil))
    checkEqual("a request without an id is refused, not dropped", reply.code(), "invalid_params")
    check((reply.id is NSNull) || reply.id == nil, "and the answer's id is null")
}
for raw in ["not json", "[]", "42"] {
    let reply = parse(await carrier.handle(Data(raw.utf8), connection: nil))
    checkEqual("a message that is not a JSON-RPC request is invalid_params (\(raw))",
               reply.code(), "invalid_params")
}
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 3]), connection: nil))
    checkEqual("a message with no method is invalid_params", reply.code(), "invalid_params")
}
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "1.0", "id": 4, "method": "ping"]),
                                           connection: nil))
    checkEqual("a wrong JSON-RPC version is invalid_params", reply.code(), "invalid_params")
}

// ── 3. The connection rule and the one-shot carrier ─────────────────────────
do {
    let connection = ThreadRpcSocketConnection()
    let before = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 5,
                                                  "method": "index/list", "params": [:]]),
                                            connection: connection))
    checkEqual("on a socket, a method before initialize is refused", before.code(),
               "unsupported_version")
    _ = parse(await carrier.handle(body([
        "jsonrpc": "2.0", "id": 6, "method": "initialize",
        "params": ["protocolVersion": 2, "client": ["kind": "mac", "label": "w", "version": "1"]],
    ]), connection: connection))
    let after = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 7,
                                                 "method": "index/list", "params": [:]]),
                                           connection: connection))
    check(after.error == nil, "after initialize the same method is served")
    checkEqual("and its result is the handler's",
               (after.result as? [String: Any])?["threads"] as? [Any] != nil, true)
}
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 8,
                                                 "method": "index/list", "params": [:]]),
                                           connection: nil))
    check(reply.error == nil, "the one-shot carrier needs no initialize")
}
for method in ThreadRpcCarrier.carrierOnlyRefused {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 9,
                                                 "method": method,
                                                 "params": ["threadId": "th-1"]]),
                                           connection: nil))
    checkEqual("the one-shot carrier refuses \(method)", reply.code(), "not_supported")
}
do {
    let connection = ThreadRpcSocketConnection()
    _ = parse(await carrier.handle(body([
        "jsonrpc": "2.0", "id": 10, "method": "initialize",
        "params": ["protocolVersion": 2, "client": ["kind": "mac", "label": "w", "version": "1"]],
    ]), connection: connection))
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 11,
                                                 "method": "thread/open",
                                                 "params": ["threadId": "th-1"]]),
                                           connection: connection))
    check(reply.error == nil, "on a socket thread/open is served")
}

// ── 4. Unknown methods, errors and the error shape ──────────────────────────
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 12,
                                                 "method": "thread/teleport", "params": [:]]),
                                           connection: nil))
    checkEqual("a method the contract does not define is not_supported", reply.code(), "not_supported")
}
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 13,
                                                 "method": "thread/history", "params": [:]]),
                                           connection: nil))
    checkEqual("a contract method with no registered handler is not_supported",
               reply.code(), "not_supported")
}
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 14,
                                                 "method": "boom/notFound", "params": [:]]),
                                           connection: nil))
    checkEqual("a handler's refusal keeps its code", reply.code(), "not_found")
    checkEqual("a handler's refusal keeps the numeric code", reply.error?["code"] as? Int, -32000)
    checkEqual("a handler's refusal keeps retryable", reply.data()["retryable"] as? Bool, false)
}
do {
    let raw = await carrier.handle(body(["jsonrpc": "2.0", "id": 15,
                                         "method": "boom/secret", "params": [:]]),
                                   connection: nil)
    let reply = parse(raw)
    checkEqual("an unexpected failure is internal", reply.code(), "internal")
    check(!String(data: raw, encoding: .utf8)!.contains("sk-secret"),
          "an unexpected failure never leaks the thrown message")
}
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 16,
                                                 "method": "index/search",
                                                 "params": ["query": "Disney"]]),
                                           connection: nil))
    let first = (reply.result as? [[String: Any]])?.first
    checkEqual("a handler's result travels unchanged", first?["snippet"] as? String, "Disney")
}
do {
    let reply = parse(await carrier.handle(body(["jsonrpc": "2.0", "id": 17,
                                                 "method": "thread/send",
                                                 "params": ["threadId": "th-42", "text": "hi",
                                                            "runOn": "auto"]]),
                                           connection: nil))
    checkEqual("the caller's threadId reaches the handler",
               ((reply.result as? [String: Any])?["turn"] as? [String: Any])?["threadId"] as? String,
               "th-42")
}

// ── 5. The ticket is spent on the socket ────────────────────────────────────
do {
    let ticket = carrier.mintTicket()
    check(ticket.count == 64, "the carrier mints a 64-hex ticket")
    check(carrier.consumeTicket(ticket), "the ticket opens one socket")
    check(!carrier.consumeTicket(ticket), "the same ticket cannot open a second socket")
    check(!carrier.consumeTicket("never-minted"), "an unknown ticket is refused")
}

finish("loopback_thread")
