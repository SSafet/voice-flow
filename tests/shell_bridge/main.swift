import Foundation

// V7, tasks 1 and 2 — the native half of the shell bridge (02 §3.6; 06 §3.13).
//
// The bridge is driven exactly as the interface drives it: one JSON line in,
// one JSON line out. Every case here uses the real contract fixtures on one
// side and the bridge's own emitted line on the other, decoded with the
// generated contract types. The host is a boundary double that only records
// what the bridge asked for; the assertion is always about what the bridge
// did, never about what the double returned.

let descriptor = try ShellFixtures.shellDescriptor()
let host = RecordingShellHost(descriptor: descriptor)
var emitted: [String] = []
let bridge = ShellBridge(host: host, emit: { emitted.append($0) })

func lastLine() -> String {
    guard let line = emitted.last else {
        fputs("FAIL: the bridge emitted nothing\n", stderr)
        exit(1)
    }
    return line
}

func decodeResponse(_ line: String) -> TPBridgeResponse {
    do { return try JSONDecoder().decode(TPBridgeResponse.self, from: Data(line.utf8)) }
    catch {
        fputs("FAIL: the emitted line is not a response envelope: \(error)\n", stderr)
        exit(1)
    }
}

func resultObject(_ line: String) -> Any {
    guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let result = object["result"] else { return [:] }
    return result
}

func decodeDescriptor(_ line: String) throws -> TPShellDescriptor {
    let data = try JSONSerialization.data(withJSONObject: resultObject(line))
    return try JSONDecoder().decode(TPShellDescriptor.self, from: data)
}

// ── 1. the version is 1, and nothing else is half answered ───────────────────

expectEqual(ShellBridge.contractVersion, 1, "the shell bridge contract version is 1 (02 §3.6)")
expectEqual(ShellBridge.transportGlobalObject, "__atikaShell",
            "the injected object's name is the contract's (K3 decision 12, 02 §3.6)")
expectEqual(ShellBridge.transportReceiveFunction, "__atikaShellReceive",
            "the receiving function's name is the contract's (K3 decision 12, 02 §3.6)")

expectEqual(bridge.receive(line: #"{"v":2,"id":"r","kind":"request","method":"shell.describe","params":{}}"#),
            .dropped(.wrongVersion(2)),
            "a request of another version is dropped, not answered")
expect(emitted.isEmpty, "nothing is emitted for a wrong-version request")

expectEqual(bridge.receive(line: "this is not json"),
            .dropped(.notJSON),
            "a line that is not JSON is dropped")
expect(emitted.isEmpty, "nothing is emitted for a line that is not JSON")

expectEqual(bridge.receive(line: #"{"v":1,"kind":"event","topic":"connectivity","data":{"online":true}}"#),
            .dropped(.notARequest),
            "the interface cannot send an event envelope to the shell")
expect(emitted.isEmpty, "nothing is emitted for an envelope that is not a request")

expectEqual(bridge.receive(line: #"{"v":1,"id":"r","kind":"request","method":"reveal","params":{}}"#),
            .dropped(.unknownMethod("reveal")),
            "a method outside the table is refused by name")

expectEqual(bridge.receive(line: #"{"v":1,"id":"r","kind":"request","method":"shell.describe"}"#),
            .dropped(.paramsMissing),
            "params is required even when it is empty")

// ── 2. every committed request fixture round-trips through the bridge ────────

let requestLines = try ShellFixtures.rawLines("BridgeRequest")
for line in requestLines {
    emitted.removeAll()
    let disposition = bridge.receive(line: line)
    guard case .responded(let id, let ok) = disposition else {
        fputs("FAIL: a BridgeRequest fixture was dropped: \(line)\n", stderr)
        exit(1)
    }
    expectEqual(emitted.count, 1, "one request gets exactly one response")
    let response = decodeResponse(lastLine())
    expectEqual(response.id, id, "the response carries the request's id")
    expectEqual(response.v, 1, "the response carries v 1")
    expectEqual(response.kind, .response, "the response envelope's kind is response")
    expectEqual(ok, response.ok, "the bridge reported the same outcome it emitted")
}

// ── 3. shell.describe answers the whole descriptor ───────────────────────────

emitted.removeAll()
_ = bridge.receive(line: #"{"v":1,"id":"d1","kind":"request","method":"shell.describe","params":{}}"#)
let descriptorResponse = decodeResponse(lastLine())
expect(descriptorResponse.ok, "shell.describe succeeds")
let answeredDescriptor = try decodeDescriptor(lastLine())
expectEqual(answeredDescriptor, descriptor, "shell.describe answers the host's descriptor unchanged")
expectEqual(answeredDescriptor.capabilities, descriptor.capabilities,
            "the capability list is the live one (02 §3.6)")

// ── 4. shell.ready records the build id ──────────────────────────────────────

emitted.removeAll()
_ = bridge.receive(line: #"{"v":1,"id":"ready","kind":"request","method":"shell.ready","params":{"buildId":"7cbe540d"}}"#)
expect(bridge.ready, "shell.ready marks the interface as painted")
expectEqual(bridge.buildID, "7cbe540d", "shell.ready records the build id the interface sent")

// ── 5. a capability the shell does not list is refused by name, never called ─

host.capabilities = []
host.calls.removeAll()
emitted.removeAll()
expectEqual(bridge.receive(line: #"{"v":1,"id":"c1","kind":"request","method":"capture.screen","params":{}}"#),
            .responded(id: "c1", ok: false),
            "a capability the shell lacks is answered")
expectEqual(decodeResponse(lastLine()).error?.code, .notSupported,
            "a capability that is not in the list answers not_supported (R5, ruling C12)")
expect(!host.calls.contains("capture.screen"), "a capability the shell lacks is never performed")
host.capabilities = allBridgeCapabilities

// ── 6. a refusal by the person is permission_denied with its permissionId ────

host.failure = .permissionDenied(permissionID: "screen-recording",
                                 message: "Screen recording is not allowed.")
emitted.removeAll()
_ = bridge.receive(line: #"{"v":1,"id":"c2","kind":"request","method":"capture.screen","params":{}}"#)
let denied = decodeResponse(lastLine())
expectEqual(denied.error?.code, .permissionDenied, "a refused permission answers permission_denied")
expectEqual(denied.error?.permissionID, "screen-recording",
            "the permissionId lets the interface offer Open settings (02 §3.6)")
host.failure = nil

// ── 7. the other fixed refusals keep their code ──────────────────────────────

let refusalCases: [(ShellBridgeError, TPBridgeErrorCode)] = [
    (.notSignedIn, .notSignedIn),
    (.cancelledByUser, .cancelledByUser),
    (.busy, .busy),
    (.notSupported(method: "notify"), .notSupported),
]
for (failure, code) in refusalCases {
    host.failure = failure
    emitted.removeAll()
    _ = bridge.receive(line: #"{"v":1,"id":"a1","kind":"request","method":"auth.token","params":{"endpointId":"cloud"}}"#)
    expectEqual(decodeResponse(lastLine()).error?.code, code, "\(failure) maps to \(code)")
}
host.failure = nil

// ── 8. params that do not fit the method are refused before the host is called

host.calls.removeAll()
emitted.removeAll()
_ = bridge.receive(line: #"{"v":1,"id":"p1","kind":"request","method":"dictate.stop","params":{}}"#)
expectEqual(decodeResponse(lastLine()).error?.code, .bridgeErrorCodeInternal,
            "params that do not fit the method are refused as internal")
expect(!host.calls.contains("dictate.stop"), "a malformed request never reaches the native capability")

// ── 9. the capability table is the contract's, method by method ──────────────

let expectedCapabilities: [(TPBridgeMethodName, TPBridgeCapability?)] = [
    (.shellDescribe, nil), (.shellReady, nil), (.shellEscape, nil),
    (.authToken, nil), (.authSignIn, nil), (.authSignOut, nil),
    (.dictateStart, .dictate), (.dictateStop, .dictate),
    (.captureScreen, .captureScreen), (.annotateStart, .annotate),
    (.speakStart, .speak), (.speakStop, .speak), (.notify, .notify),
    (.filesPick, .filesPick), (.filesPickFolder, .filesPickFolder),
    (.filesSave, .filesSave), (.filesReveal, .filesReveal),
    (.permissionsList, .permissions), (.permissionsOpen, .permissions),
    (.routeChanged, nil), (.pinsReport, nil),
    (.externalOpen, .externalOpen), (.composerRefuse, nil),
]
for (method, capability) in expectedCapabilities {
    expectEqual(ShellBridge.capability(for: method), capability,
                "\(method.rawValue) is gated by \(capability.map(\.rawValue) ?? "nothing")")
}

// ── 10. composer.refuse carries the shape the contract refines ───────────────

host.calls.removeAll()
emitted.removeAll()
_ = bridge.receive(line: #"{"v":1,"id":"k1","kind":"request","method":"composer.refuse","params":{"topic":"composer.insert","threadId":"t1","reason":"thread_unknown"}}"#)
expectEqual(decodeResponse(lastLine()).ok, true, "a valid composer.refuse is answered ok")
expect(host.calls.contains("composer.refuse"), "the refusal reaches the host")

host.calls.removeAll()
emitted.removeAll()
_ = bridge.receive(line: #"{"v":1,"id":"k2","kind":"request","method":"composer.refuse","params":{"topic":"composer.insert","reason":"thread_unknown"}}"#)
expectEqual(decodeResponse(lastLine()).error?.code, .bridgeErrorCodeInternal,
            "thread_unknown without a thread is refused")
expect(!host.calls.contains("composer.refuse"), "a refusal that breaks the contract never reaches the host")

// ── 11. closing the bridge ends the open native sessions (W4 ruling) ─────────
//
// annotate.start has no timeout: the person ends it by finishing or cancelling,
// and the closing of the bridge connection ends it. The bridge tells its host,
// and afterwards answers nothing.

emitted.removeAll()
_ = bridge.receive(line: #"{"v":1,"id":"a1","kind":"request","method":"annotate.start","params":{"threadId":"t1"}}"#)
expectEqual(decodeResponse(lastLine()).ok, true, "annotate.start is answered")
bridge.shutdown()
expectEqual(host.closedCount, 1, "closing the bridge tells the host once")
expectEqual(bridge.receive(line: #"{"v":1,"id":"a2","kind":"request","method":"shell.describe","params":{}}"#),
            .dropped(.closed),
            "a closed bridge answers nothing")

print("shell bridge: \(requestLines.count) request fixtures, the capability table and every named refusal passed")
