import Foundation
import AppKit
import CryptoKit
import MCP
import GRDB

func vflog(_ message: String) {}
final class PendingInteraction { var sessionId: String? }
struct CaptureSummary {}
final class UserSettings {
    static let shared = UserSettings()
    var watcherKeepDays = 30
    var watcherDenseApps: Set<String> = []
}
struct ProofFailure: Error { let message: String }
final class Proof: @unchecked Sendable {
    var assertions = 0
    func check(_ ok: Bool, _ message: String) throws {
        assertions += 1
        guard ok else { throw ProofFailure(message: message) }
        print("PASS \(message)")
    }
    func refuses(_ code: String, _ body: () async throws -> Void) async throws {
        do { try await body(); throw ProofFailure(message: "expected \(code)") }
        catch let failure as T3NativeToolFailure { try check(failure.code == code, code) }
    }
}
final class State: @unchecked Sendable {
    let lock = NSLock()
    var decision: T3NativeToolDecision = .allow
    var revision = "policy-v1"
    var enabled = true
    var effects = 0
    var checks = 0
    var denyAt: Int?
    func authority(_ binding: T3NativeToolBinding) -> T3NativeToolAuthority? {
        lock.withLock {
            checks += 1
            if let denyAt, checks >= denyAt { enabled = false }
            return enabled ? .init(binding: binding, backendRevision: "native-v1", policyRevision: revision, decision: decision) : nil
        }
    }
}
actor Gate {
    var started = false
    var continuation: CheckedContinuation<Void, Never>?
    func park() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil; started = false }
}
func until(_ test: () async -> Bool) async throws {
    for _ in 0..<300 { if await test() { return }; try await Task.sleep(for: .milliseconds(10)) }
    throw ProofFailure(message: "timed out")
}
func values(_ input: [String: Any]) throws -> [String: Value] {
    try JSONDecoder().decode([String: Value].self, from: JSONSerialization.data(withJSONObject: input))
}
func json<T: Encodable>(_ input: T) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as! [String: Any]
}
func resultJSON(_ result: CallTool.Result) throws -> [String: Any] {
    guard let content = result.structuredContent else { throw ProofFailure(message: "no structured content") }
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(content)) as! [String: Any]
}
func image(_ width: Int, _ height: Int) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height)); return context.makeImage()!
}
@main struct NativeToolsProof {
    static func main() async throws {
        guard VoiceFlowPaths.shared.isIsolated else { fatalError("isolated root required") }
        let proof = Proof(), state = State()
        let binding = T3NativeToolBinding(environment: .init(environmentId: "fixture-env", launchGeneration: UUID()),
                                         ownerId: "fixture-owner", deviceId: "fixture-device", homeId: "fixture-home", identityGeneration: UUID().uuidString)
        let tools = try T3NativeToolCatalog.tools(computer: true, captured: true, overlay: true)
        let backend = T3NativeToolBackend(authority: { _, _ in state.authority(binding) }, perform: { _, _, checkpoint in
            try checkpoint.check(); state.lock.withLock { state.effects += 1 }; return .init(content: [.text("performed")], isError: false)
        })
        func makeService(capacity: Int = 4096, backend override: T3NativeToolBackend? = nil) throws -> T3NativeToolService {
            try T3NativeToolService(binding: binding, backendRevision: "native-v1", policyRevision: "policy-v1", tools: tools,
                                    backend: override ?? backend, capacity: capacity)
        }
        let service = try makeService()
        let manifest = await service.manifest
        func call(_ id: String, args: [String: Any] = ["action":"type","text":"secret-password"], tool: String = "voiceflow_computer", thread: String = "thread", turn: String = "turn") throws -> T3NativeToolCall {
            .init(threadId: thread, turnId: turn, callId: id, tool: tool, arguments: try values(args), manifestRevision: manifest.revision)
        }
        try proof.check(tools.count == 7 && !tools.contains(where: { $0.name.contains("queue") || $0.name == "user" }), "native manifest contains only connected native families")
        let otherPolicy = try T3NativeToolService(binding: binding, backendRevision: "native-v1", policyRevision: "policy-v2", tools: tools, backend: backend)
        try proof.check(await otherPolicy.manifest.revision != manifest.revision, "policy is part of manifest identity")
        let otherBackend = try T3NativeToolService(binding: binding, backendRevision: "native-v2", policyRevision: "policy-v1", tools: tools, backend: backend)
        try proof.check(await otherBackend.manifest.revision != manifest.revision, "backend is part of manifest identity")
        let nextBinding = T3NativeToolBinding(environment: .init(environmentId: binding.environment.environmentId, launchGeneration: UUID()), ownerId: binding.ownerId, deviceId: binding.deviceId, homeId: binding.homeId, identityGeneration: binding.identityGeneration)
        let nextLaunch = try T3NativeToolService(binding: nextBinding, backendRevision: "native-v1", policyRevision: "policy-v1", tools: tools, backend: backend)
        try proof.check(await nextLaunch.manifest.revision != manifest.revision, "launch is part of manifest identity")
        let first = try call("first")
        let admission = try await service.preflight(first)
        try proof.check(admission.decision == .allow && admission.executionToken != nil, "allow issues one-use capability")
        try proof.check(!admission.review.contains("secret-password") && admission.review.contains("[redacted]") && admission.review.utf8.count <= 4096, "approval description redacts secret argument")
        try proof.check(try await service.preflight(first) == admission, "duplicate exact preflight is stable")
        try await proof.refuses("native_call_changed") { _ = try await service.preflight(call("first", args: ["action":"type","text":"changed"])) }
        let wrongToken = await service.execute(first, token: "wrong")
        try proof.check(wrongToken.isError == true && state.effects == 0, "wrong token performs no effect")
        let results = await withTaskGroup(of: CallTool.Result.self, returning: [CallTool.Result].self) { group in
            for _ in 0..<2 { group.addTask { await service.execute(first, token: admission.executionToken!) } }
            var results: [CallTool.Result] = []; for await result in group { results.append(result) }; return results
        }
        try proof.check(results.filter { $0.isError != true }.count == 1 && state.effects == 1, "concurrent duplicate call performs once")
        try await proof.refuses("native_already_consumed") { _ = try await service.preflight(first) }
        state.decision = .ask
        let pending = try call("ask"), ask = try await service.preflight(pending)
        try proof.check(ask.decision == .ask && ask.requestId != nil && ask.executionToken == nil, "ask emits bound request ID and no execution")
        try await proof.refuses("native_approval_stale") { _ = try await service.approve(pending, requestId: "wrong", allowOnce: true) }
        let approved = try await service.approve(pending, requestId: ask.requestId!, allowOnce: true)
        try proof.check(approved.decision == .allow, "exact allow-once issues execution")
        try await proof.refuses("native_approval_stale") { _ = try await service.approve(pending, requestId: ask.requestId!, allowOnce: false) }
        try proof.check(await service.execute(pending, token: approved.executionToken!).isError != true, "approved ask executes once")
        let rejected = try call("reject"), rejectAsk = try await service.preflight(rejected)
        _ = try await service.approve(rejected, requestId: rejectAsk.requestId!, allowOnce: false)
        try await proof.refuses("native_approval_stale") { _ = try await service.approve(rejected, requestId: rejectAsk.requestId!, allowOnce: true) }
        state.decision = .allow
        let changed = try call("changed"), old = try await service.preflight(changed)
        state.decision = .ask
        try proof.check(await service.execute(changed, token: old.executionToken!).isError == true, "allow-to-ask cannot bypass new approval")
        state.decision = .deny
        try proof.check(try await service.preflight(call("denied")).decision == .deny, "hard deny has no runtime-mode bypass")
        state.decision = .allow; state.revision = "changed"
        try await proof.refuses("native_authority_changed") { _ = try await service.preflight(call("policy-change")) }
        state.revision = "policy-v1"
        let gate = Gate()
        let blocked = try makeService(backend: .init(authority: { _, _ in state.authority(binding) }, perform: { _, _, checkpoint in
            await gate.park(); try checkpoint.check(); state.lock.withLock { state.effects += 1 }; return .init(content: [.text("effect")])
        }))
        let blockedCall = try call("closed"), blockedAuth = try await blocked.preflight(blockedCall)
        let waiting = Task { await blocked.execute(blockedCall, token: blockedAuth.executionToken!) }
        try await until { await gate.started }
        let beforeClose = state.effects
        try await blocked.closeTurn(threadId: "thread", turnId: "turn"); await gate.release()
        try proof.check(await waiting.value.isError == true && state.effects == beforeClose, "closed turn revokes in-flight effect")
        try await proof.refuses("native_call_invalid") { _ = try await blocked.preflight(blockedCall) }
        let capacity = try makeService(capacity: 1)
        _ = try await capacity.preflight(call("capacity1"))
        try await proof.refuses("native_capacity") { _ = try await capacity.preflight(call("capacity2")) }
        var clock = Date(timeIntervalSince1970:1_000)
        let expiring = try T3NativeToolService(binding:binding,backendRevision:"native-v1",policyRevision:"policy-v1",tools:tools,backend:backend,now:{clock})
        let expiredCall = try call("expired"), expires = try await expiring.preflight(expiredCall)
        clock += 601
        try proof.check(await expiring.execute(expiredCall,token:expires.executionToken!).isError == true,"expired token performs no effect")
        expiring.revoke()
        try await proof.refuses("native_revoked") { _ = try await expiring.preflight(expiredCall) }
        try await primitives(proof, binding, state, tools)
        try await configuration(proof, binding, tools)
        try await http(proof, binding, state, tools)
        try computerEvents(proof)
        print("PASS \(proof.assertions) isolated native tool assertions")
    }
    static func primitives(_ proof: Proof, _ binding: T3NativeToolBinding, _ state: State, _ tools: [Tool]) async throws {
        let root = VoiceFlowPaths.shared.configRoot, fm = FileManager.default
        let pool = try CapturedDatabase.open(at: CapturedDatabase.url(configRoot: root)), index = CapturedIndex(pool: pool)
        let png = NSBitmapImageRep(cgImage: image(400, 200)).representation(using: .png, properties: [:])!
        let source = root.appendingPathComponent("captures/shots/fixture.png")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: source)
        let sourceHash = SHA256.hash(data: png).description
        try index.upsert(.init(id: "shot:fixture", kind: .shot, source: .shot, tStart: 123, tEnd: 123,
                              imgW: 400, imgH: 200, path: "captures/shots/fixture.png", imageState: .present))
        let overlayRoot = root.appendingPathComponent("fixture-overlays")
        try fm.createDirectory(at: overlayRoot, withIntermediateDirectories: true)
        var received: [T3NativeComputerCommand] = []
        var geometry: CGRect? = CGRect(x: -800, y: 200, width: 800, height: 400)
        let computer = T3NativeComputerPrimitives(capture: { .init(displayId: 9, bounds: CGRect(x: -800, y: 200, width: 800, height: 400), image: image(400,200)) }, geometry: { _ in geometry }, cursor: { CGPoint(x: -400,y:400) }, perform: { command, checkpoint in try checkpoint.check(); received.append(command) })
        let overlays = T3NativeOverlayPrimitives(list: { (try? fm.contentsOfDirectory(atPath: overlayRoot.path)) ?? [] }, read: { id in
            (try? Data(contentsOf: overlayRoot.appendingPathComponent(id))).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }, write: { id, payload in try JSONSerialization.data(withJSONObject: payload).write(to: overlayRoot.appendingPathComponent(id), options: .atomic) }, remove: { id in try fm.removeItem(at: overlayRoot.appendingPathComponent(id)) })
        var queryChecks = 0, denyQueryCheck: Int?
        let primitives = T3NativeToolPrimitives(binding: binding, computer: computer, overlays: overlays, captured: { checkpoint in
            CapturedReadService(query: CapturedQuery(index: index, root: root, mayRead: {
                queryChecks += 1
                if queryChecks == denyQueryCheck { state.enabled = false }
                return (try? checkpoint.check()) != nil
            }))
        })
        let service = try T3NativeToolService(binding: binding, backendRevision: "native-v1", policyRevision: "policy-v1", tools: tools,
            backend: .init(authority: { _, _ in state.authority(binding) }, perform: { call, operation, checkpoint in
                try await primitives.execute(call, operation, checkpoint)
            }))
        let manifest = await service.manifest
        func invoke(_ id: String, _ args: [String: Any], tool: String = "voiceflow_computer", thread: String = "thread") async throws -> CallTool.Result {
            let call = T3NativeToolCall(threadId: thread, turnId: "turn", callId: id, tool: tool, arguments: try values(args), manifestRevision: manifest.revision)
            let admission = try await service.preflight(call)
            return await service.execute(call, token: admission.executionToken!)
        }
        let shot = try await invoke("shot", ["action":"screenshot"])
        let metadata = try resultJSON(shot), screenId = metadata["screenId"] as! String
        try proof.check(shot.isError == false && shot.content.count == 2, "screenshot returns actual image block and dimensions")
        if case .image(let base64, let mime, _, _) = shot.content[1] {
            let data = Data(base64Encoded: base64)!
            let image = NSBitmapImageRep(data: data)
            try proof.check(data.count <= 400_000 && mime == "image/jpeg" && image?.pixelsWide == metadata["width"] as? Int, "screenshot bytes decode at advertised size")
        } else { throw ProofFailure(message: "image block absent") }
        let annotation = try await invoke("annotation", ["operation":"annotate","id":"mark","screenId":screenId,"payload":["items":[["type":"arrow","from":[0,0],"to":[200,100]]]]], tool:"voiceflow_overlay")
        let annotationDoc = overlays.read(overlays.list()[0])!
        let annotationItem = (annotationDoc["items"] as! [[String:Any]])[0]
        try proof.check(annotation.isError == false && annotationDoc["display_id"] as? Int == 9 && annotationItem["to"] as? [Double] == [400,200], "annotation converts actual screenshot pixels to existing overlay geometry")
        _ = try await invoke("removeAnnotation", ["operation":"remove","id":"mark"], tool:"voiceflow_overlay")
        let drag = try await invoke("drag", ["action":"drag","screenId":screenId,"start_coordinate":[0,0],"coordinate":[200,100]])
        try proof.check(drag.isError == false && received.last?.action == "drag" && received.last?.start == CGPoint(x:-800,y:200) && received.last?.point == CGPoint(x:-400,y:400), "drag maps both endpoints from image to nonzero display origin")
        let cursor = try resultJSON(await invoke("cursor", ["action":"cursor_position"]))
        try proof.check(cursor["coordinate"] as? [Double] == [200,100], "cursor uses same screenshot coordinate frame")
        let outside = try await invoke("outside", ["action":"left_click","screenId":screenId,"coordinate":[400,200]])
        try proof.check(outside.isError == true && received.count == 1, "outside screenshot coordinates never reach native control")
        _ = try await invoke("newshot", ["action":"screenshot"])
        let stale = try await invoke("stale", ["action":"left_click","screenId":screenId,"coordinate":[2,2]])
        try proof.check(stale.isError == true && received.count == 1, "replaced screenshot cannot control Mac")
        geometry = nil
        let missingDisplay = try await invoke("missing", ["action":"screenshot"])
        try proof.check(missingDisplay.isError == true, "disappearing display returns error")
        geometry = CGRect(x:-800,y:200,width:800,height:400)
        let captured = try await invoke("captured", ["id":"shot:fixture","picture":true], tool:"captured_get")
        try proof.check(captured.isError == false && captured.content.contains { if case .image = $0 { true } else { false } }, "real SQLite CapturedReadService returns ImageIO bytes through SDK content")
        let missingCapture = try await invoke("missingCapture", ["id":"shot:missing","picture":true], tool:"captured_get")
        try proof.check(missingCapture.isError == true, "missing captured source retains truthful MCP isError")
        try proof.check(SHA256.hash(data: Data(contentsOf:source)).description == sourceHash, "captured original bytes unchanged")
        let show = try await invoke("overlay", ["operation":"show_panel","id":"plan","payload":["session":"forged","system":true,"title":"hello","blocks":[["kind":"text","text":"fixture"]]]], tool:"voiceflow_overlay")
        try proof.check(show.isError == false, "overlay writes through injected existing-service boundary")
        let ids = overlays.list(), document = overlays.read(ids[0])!
        try proof.check(document["session"] as? String == T3NativeToolPrimitives.overlayOwner(binding:binding,threadId:"thread") && document["system"] as? Bool == false, "overlay owner and system marker cannot be forged")
        let list = try resultJSON(await invoke("list", ["operation":"list"], tool:"voiceflow_overlay"))
        try proof.check((list["overlays"] as? [[String:Any]])?.first?["id"] as? String == "plan" && !String(describing:list).contains(root.path), "overlay list exposes own IDs without native paths")
        let other = try resultJSON(await invoke("other", ["operation":"list"], tool:"voiceflow_overlay", thread:"other"))
        try proof.check((other["overlays"] as? [Any])?.isEmpty == true, "other thread sees no overlay")
        let remove = try await invoke("remove", ["operation":"remove","id":"plan"], tool:"voiceflow_overlay")
        try proof.check(remove.isError == false && overlays.list().isEmpty, "owned overlay removal verifies bytes removed")
        // Revoke while the real query is preparing image bytes. Query checks more
        // than once; the service checkpoint must also suppress the entire reply.
        let checksBefore = state.checks
        state.denyAt = checksBefore + 6
        let revoked = try await invoke("revokedCapture", ["id":"shot:fixture","picture":true], tool:"captured_get")
        try proof.check(revoked.isError == true && !revoked.content.contains { if case .image = $0 { true } else { false } }, "revocation during captured read publishes no image")
        state.enabled = true; state.denyAt = nil
        try proof.check(SHA256.hash(data: Data(contentsOf:source)).description == sourceHash, "revocation does not mutate original capture")
        for n in 0..<2 {
            try index.upsert(.init(id:"frame:multi\(n)",kind:.frame,source:.watcher,tStart:200+n,tEnd:200+n,
                                  path:"captures/shots/fixture.png",imageState:.present))
        }
        queryChecks = 0; denyQueryCheck = 4
        let multi = try await invoke("multi",["from":"1970-01-01T00:03:19Z","to":"1970-01-01T00:03:30Z","maxPictures":2],tool:"captured_frames")
        try proof.check(queryChecks == 4 && multi.isError == true && !multi.content.contains { if case .image = $0 { true } else { false } }, "revocation between first and second real captured image discards all bytes")
        state.enabled = true; denyQueryCheck = nil
        let multiAllowed = try await invoke("multiAllowed",["from":"1970-01-01T00:03:19Z","to":"1970-01-01T00:03:30Z","maxPictures":2],tool:"captured_frames")
        try proof.check(multiAllowed.content.filter { if case .image = $0 { true } else { false } }.count == 2, "same real captured range has two deliverable images when authorized")
        let link = source.deletingLastPathComponent().appendingPathComponent("unsafe.png")
        try fm.createSymbolicLink(at:link,withDestinationURL:source)
        try index.upsert(.init(id:"shot:unsafe",kind:.shot,source:.shot,tStart:124,tEnd:124,path:"captures/shots/unsafe.png",imageState:.present))
        let unsafe = try await invoke("unsafe",["id":"shot:unsafe","picture":true],tool:"captured_get")
        try proof.check(!unsafe.content.contains { if case .image = $0 { true } else { false } }, "real no-follow captured owner never delivers symlink bytes")
        print("SOURCE SHA256 \(sourceHash)")
    }
    static func configuration(_ proof: Proof, _ binding: T3NativeToolBinding, _ tools: [Tool]) async throws {
        func settings(_ budget: Double = 5, model: String = "deepseek/deepseek-v4.1-flash", roots: [String] = ["~/projects"]) -> T3NativeSettings {
            .init(runCommands: true, reachNetwork: false, assistantComputerUse: false, workspaceRoots: roots,
                  egressAllow: [], egressBlock: ["blocked.example"], dailyBudgetUSD: budget, model: model, reasoningEffort: "")
        }
        let config = try T3NativeConfiguration(binding: binding, settings: settings(), decisions: .init(contextRead: .allow, editWorkspace: .ask, shell: .ask))
        try proof.check(config.revision.count == 64 && config.policyRevision.count == 64 && config.settings.reasoningEffort == "", "configuration preserves unset effort and exact tilde root")
        try proof.check(try T3NativeConfiguration(binding: binding, settings: settings(), decisions: .init(contextRead: .allow, editWorkspace: .ask, shell: .ask)).revision == config.revision, "configuration encoding yields stable revision")
        try proof.check(try T3NativeConfiguration(binding: binding, settings: settings(6), decisions: .init(contextRead: .allow, editWorkspace: .ask, shell: .ask)).revision != config.revision, "budget participates in configuration revision")
        for invalid in [settings(.nan), settings(-1), settings(10_001), settings(model: "invalid model"), settings(roots: ["/tmp/secret\npath"])] {
            do { try invalid.validate(); throw ProofFailure(message: "invalid configuration accepted") }
            catch let error as T3NativeToolFailure { try proof.check(error.code == "native_settings_invalid", "invalid settings refused") }
        }
        let life = T3NativeToolLifetime()
        let service = try T3NativeToolService(binding: binding, backendRevision: "native-v1", policyRevision: config.policyRevision, tools: tools,
            backend: .init(authority: { _,_ in nil }, perform: { _,_,_ in throw ProofFailure(message: "unexpected effect") }))
        let host = T3NativeToolMCP(service: service, environment: binding.environment, configuration: {
            try life.check(); return config
        }, onTurnClosed: { _,_ in })
        func request(_ version: Int) throws -> HTTPRequest {
            .init(method: "POST", headers: ["Accept":"application/json, text/event-stream", "Content-Type":"application/json"],
                  body: try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1, "method":"atika/native/configuration", "params":["version":version]]), path:"/v1/tools/mcp")
        }
        func result(_ host: T3NativeToolMCP, version: Int = 1) async throws -> [String:Any] {
            let response = await host.handle(try request(version), ownedEnvironment: binding.environment)
            return try JSONSerialization.jsonObject(with: response.bodyData!) as! [String:Any]
        }
        let wire = try await result(host)
        let value = wire["result"] as! [String:Any]
        try proof.check(value["revision"] as? String == config.revision && (value["settings"] as? [String:Any])?["reachNetwork"] as? Bool == false, "actual SDK custom method returns native configuration and binding")
        try proof.check(try await result(host, version: 2)["error"] != nil, "unsupported configuration version refuses")
        life.revoke()
        try proof.check(try await result(host)["error"] != nil, "configuration revocation refuses before publication")
        await host.stop()
        let absent = T3NativeToolMCP(service: service, environment: binding.environment, onTurnClosed: { _,_ in })
        // A fresh service is needed because stopping a host revokes its shared launch.
        let fresh = try T3NativeToolService(binding: binding, backendRevision: "native-v1", policyRevision: config.policyRevision, tools: tools,
            backend: .init(authority: { _,_ in nil }, perform: { _,_,_ in throw ProofFailure(message: "unexpected effect") }))
        let absentFresh = T3NativeToolMCP(service: fresh, environment: binding.environment, onTurnClosed: { _,_ in })
        try proof.check(try await result(absentFresh)["error"] != nil, "unconfigured services explicitly refuse configuration method")
        await absentFresh.stop(); await absent.stop()
    }
    static func http(_ proof: Proof, _ binding: T3NativeToolBinding, _ state: State, _ tools: [Tool]) async throws {
        let gate = Gate(), cancellationObserved = State()
        let service = try T3NativeToolService(binding:binding,backendRevision:"native-v1",policyRevision:"policy-v1",tools:tools,
            backend:.init(authority:{ _,_ in state.authority(binding) },perform:{ _,_,checkpoint in
                await withTaskCancellationHandler(operation:{ await gate.park() },onCancel:{ cancellationObserved.lock.withLock { cancellationObserved.effects += 1 } })
                try checkpoint.check(); state.lock.withLock { state.effects += 1 }
                return .init(content:[.text("performed")],isError:false)
            }))
        let closed = State()
        let host = T3NativeToolMCP(service:service,environment:binding.environment,onTurnClosed:{ _,_ in closed.lock.withLock { closed.effects += 1 } })
        func request(_ method:String, _ params:[String:Any], id:Int? = 1) throws -> HTTPRequest {
            var body:[String:Any] = ["jsonrpc":"2.0","method":method,"params":params]
            if let id { body["id"] = id }
            return .init(method:"POST",headers:["Accept":"application/json, text/event-stream","Content-Type":"application/json","MCP-Protocol-Version":"2025-11-25"],body:try JSONSerialization.data(withJSONObject:body),path:"/v1/tools/mcp")
        }
        func response(_ response:HTTPResponse) throws -> [String:Any] {
            guard let data = response.bodyData else { throw ProofFailure(message:"missing HTTP response body") }
            return try JSONSerialization.jsonObject(with:data) as! [String:Any]
        }
        let wrong = await host.handle(try request("tools/list",[:]),ownedEnvironment:.init(environmentId:"other",launchGeneration:UUID()))
        try proof.check(wrong.statusCode == 403,"MCP refuses wrong owned child before SDK dispatch")
        let list = try response(await host.handle(request("tools/list",[:]),ownedEnvironment:binding.environment))
        let listing = list["result"] as! [String:Any], meta = listing["_meta"] as! [String:Any]
        let manifest = meta["ai.atika/nativeManifest"] as! [String:Any]
        try proof.check((listing["tools"] as? [Any])?.count == 7 && manifest["backendRevision"] as? String == "native-v1", "real SDK tools/list carries frozen manifest metadata")
        let actualBinding = manifest["binding"] as! [String:Any], actualEnv = actualBinding["environment"] as! [String:Any]
        try proof.check(actualBinding["identityGeneration"] as? String == binding.identityGeneration && actualEnv["launchGeneration"] as? String == binding.environment.launchGeneration.uuidString, "SDK manifest exposes exact leased identity and launch UUID")
        let call:T3NativeToolCall = .init(threadId:"http-thread",turnId:"http-turn",callId:"http-call",tool:"voiceflow_computer",arguments:try values(["action":"wait","duration":0]),manifestRevision:manifest["revision"] as! String)
        state.decision = .ask
        let askResponse = try response(await host.handle(request("voiceflow/native/preflight",["version":1,"call":json(call)],id:2),ownedEnvironment:binding.environment))
        let ask = askResponse["result"] as! [String:Any]
        try proof.check(ask["decision"] as? String == "ask", "real SDK custom preflight preserves ask")
        let approvedResponse = try response(await host.handle(request("voiceflow/native/approve",["version":1,"call":json(call),"requestId":ask["requestId"]!,"decision":"allow-once"],id:3),ownedEnvironment:binding.environment))
        let approved = approvedResponse["result"] as! [String:Any]
        let exec = try request("tools/call",["name":call.tool,"arguments":json(call.arguments),"_meta":["ai.atika/nativeCall":["version":1,"threadId":call.threadId,"turnId":call.turnId,"callId":call.callId,"manifestRevision":call.manifestRevision,"executionToken":approved["executionToken"]!]]],id:4)
        let before = state.effects
        let work = Task { await host.handle(exec,ownedEnvironment:binding.environment) }
        try await until { await gate.started }
        let duplicate = await host.handle(exec,ownedEnvironment:binding.environment)
        try proof.check(duplicate.statusCode == 409,"duplicate in-flight SDK request ID is refused")
        var aliased = try JSONSerialization.jsonObject(with:exec.body!) as! [String:Any]
        aliased["id"] = "4"
        let aliasRequest = HTTPRequest(method:"POST",headers:exec.headers,body:try JSONSerialization.data(withJSONObject:aliased),path:"/v1/tools/mcp")
        try proof.check(await host.handle(aliasRequest,ownedEnvironment:binding.environment).statusCode == 409,"numeric and string SDK response-waiter IDs cannot alias")
        work.cancel(); await gate.release()
        let cancelled = try response(await work.value)
        try proof.check((cancelled["result"] as? [String:Any])?["isError"] as? Bool == true && state.effects == before,"broker-task cancellation crosses SDK task boundary and prevents effects")
        let retry = try response(await host.handle(exec,ownedEnvironment:binding.environment))
        try proof.check((retry["result"] as? [String:Any])?["isError"] as? Bool == true,"uncertain cancelled call cannot be resent")
        let sdkCall = T3NativeToolCall(threadId:call.threadId,turnId:call.turnId,callId:"sdk-cancel",tool:call.tool,arguments:call.arguments,manifestRevision:call.manifestRevision)
        state.decision = .allow
        let sdkAdmission = try await service.preflight(sdkCall)
        let sdkRequest = try request("tools/call",["name":call.tool,"arguments":json(call.arguments),"_meta":["ai.atika/nativeCall":["version":1,"threadId":call.threadId,"turnId":call.turnId,"callId":sdkCall.callId,"manifestRevision":call.manifestRevision,"executionToken":sdkAdmission.executionToken!]]],id:5)
        let sdkWork = Task { await host.handle(sdkRequest,ownedEnvironment:binding.environment) }
        try await until { await gate.started }
        let notification = await host.handle(try request("notifications/cancelled",["requestId":5],id:nil),ownedEnvironment:binding.environment)
        // Observe SDK task cancellation, not a guessed dispatch delay.
        try await until { cancellationObserved.lock.withLock { cancellationObserved.effects > 0 } }; await gate.release()
        let sdkCancelled = try response(await sdkWork.value)
        try proof.check(notification.statusCode == 202 && (sdkCancelled["result"] as? [String:Any])?["isError"] as? Bool == true && state.effects == before,"standard SDK cancellation prevents later effect and releases JSON waiter")
        let close = try response(await host.handle(request("voiceflow/native/closeTurn",["version":1,"threadId":call.threadId,"turnId":call.turnId],id:6),ownedEnvironment:binding.environment))
        try proof.check((close["result"] as? [String:Any])?["closed"] as? Bool == true && closed.effects == 1,"SDK closeTurn invokes native geometry cleanup")
        try await proof.refuses("native_call_invalid") { _ = try await service.preflight(sdkCall) }
        await host.stop()
        try proof.check(await host.handle(request("tools/list",[:]),ownedEnvironment:binding.environment).statusCode == 403,"host stop revokes admission")
        state.decision = .allow
    }
    static func computerEvents(_ proof: Proof) throws {
        var events:[CGEventType] = []
        let control = ComputerControl(eventPoster:{ events.append($0.type) })
        control.checkpoint = { if events.contains(.leftMouseDown) { throw T3NativeToolFailure(code:"cancelled") } }
        control.drag(from:CGPoint(x:1,y:1),to:CGPoint(x:20,y:20))
        try proof.check(events == [.mouseMoved,.leftMouseDown,.leftMouseUp] && control.lastFailure != nil,"interrupted drag posts only required mouse-up cleanup")
        events = []; control.checkpoint = { if events.contains(.keyDown) { throw T3NativeToolFailure(code:"cancelled") } }
        control.typeText("should not finish")
        try proof.check(events == [.keyDown,.keyUp] && control.lastFailure != nil,"interrupted text posts only required key-up cleanup")
        events = []; control.checkpoint = { throw T3NativeToolFailure(code:"revoked") }
        control.click(action:"double_click",at:.zero,modifiers:nil)
        try proof.check(events.isEmpty && control.lastFailure != nil,"revoked checkpoint prevents first computer event")
        events = []; control.checkpoint = nil
        control.drag(from:CGPoint(x:1,y:1),to:CGPoint(x:20,y:20))
        try proof.check(events.first == .mouseMoved && events.contains(.leftMouseDragged) && events.last == .leftMouseUp && control.lastFailure == nil,"existing CGEvent drag sequence preserved with injected non-posting sink")
    }
}
