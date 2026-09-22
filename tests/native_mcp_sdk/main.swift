import Foundation
import MCP
func vflog(_ message: String) {}
struct Failure: Error { let text: String }
func check(_ ok: @autoclosure () -> Bool, _ text: String) throws {
    if !ok() { throw Failure(text: text) }; print("PASS \(text)")
}
func until(_ test: () -> Bool) async throws {
    let end = Date().addingTimeInterval(3)
    while !test() { if Date() > end { throw Failure(text: "condition timed out") }; try await Task.sleep(for: .milliseconds(10)) }
}
@main struct Proof {
    static func main() async throws {
        guard VoiceFlowPaths.shared.isIsolated, ProcessInfo.processInfo.environment["VOICE_FLOW_QA_PORT"] != nil else { fatalError("isolated root/port required") }
        let absentListener = VoiceFlowPaths.shared.file("absent-vf")
        try check(MCPServer.replyListenerAdvice(sessionID: "fixture", executable: absentListener).contains("Reply listener unavailable"), "absent listener reports unavailable wake-up")
        let fixtureListener = VoiceFlowPaths.shared.file("fixture-vf")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fixtureListener)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixtureListener.path)
        try check(MCPServer.replyListenerAdvice(sessionID: "fixture", executable: fixtureListener).contains("--attach fixture --timeout 7200"), "installed listener keeps existing attach command")
        var instant = Date(timeIntervalSince1970: 100_000)
        let registry = MCPSessionRegistry(now: { instant })
        let held = registry.begin()
        registry.beginActivity(held.id)
        instant += 14_400
        try check(registry.count == 1, "four-hour in-flight session survives idle pruning")
        registry.endActivity(held.id)
        try check(registry.count == 1, "completed held call refreshes identity idle lease")
        instant += 7_201
        try check(registry.count == 0, "idle completed session still prunes after two hours")
        let mcp = MCPServer(), http = LocalAPIServer(), inbox = MessageInbox()
        let questionStarted = DispatchSemaphore(value: 0), question = DispatchSemaphore(value: 0)
        let afterDrain = DispatchSemaphore(value: 0), releaseResult = DispatchSemaphore(value: 0)
        let beforeClaim = DispatchSemaphore(value: 0), releaseClaim = DispatchSemaphore(value: 0)
        let cancelledAtClaim = DispatchSemaphore(value: 0)
        mcp.callTool = { name, args, session, cancellation in
            let claim: () -> Bool = {
                if args["pause_before_claim"] as? Bool == true {
                    cancellation.onCancel { cancelledAtClaim.signal() }
                    beforeClaim.signal()
                    releaseClaim.wait()
                }
                return cancellation.claimConsumption()
            }
            let finish: ([InboxMessage]) -> MCPServer.ToolResult = { messages in
                if args["pause_after_drain"] as? Bool == true { afterDrain.signal(); releaseResult.wait() }
                return .ok(messages.map(\.text).joined(separator: ","))
            }
            switch name {
            case "set_session_name":
                _ = mcp.sessions.rename(session!.id, to: args["name"] as? String ?? ""); return .ok("named")
            case "wait_for_message":
                _ = mcp.sessions.markEngaged(session!.id)
                let result = inbox.wait(timeout: 3600, session: session?.id, isCancelled: { cancellation.isCancelled }, beforeConsume: claim,
                    onPark: { parked in cancellation.onCancel { parked.signal() } })
                return finish(result.messages)
            case "check_messages": return finish(inbox.drain(session: session?.id, beforeConsume: claim))
            case "report_to_user":
                _ = mcp.sessions.markEngaged(session!.id)
                if args["question"] != nil { questionStarted.signal(); cancellation.wait(question, timeout: 14_400) }
                return .ok("reported")
            default: return .ok(session?.id ?? "none")
            }
        }
        http.onMCP = { method, headers, body in await mcp.handleHTTP(method: method, headers: headers, body: body) }
        http.onStatus = { .ok(["tts": "ready"]) }
        http.onSet = { .ok(["voice": $0.voice ?? "unset"]) }
        http.onSpeak = { .ok(["text": $0.text ?? ""]) }
        http.onSeek = { .ok(["position": $0.position ?? 0]) }
        http.onStop = { .ok(["stopped": true]) }
        http.start()
        let endpoint = URL(string: http.baseURL + "/mcp")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 20; configuration.timeoutIntervalForRequest = 8
        let network = URLSession(configuration: configuration)
        func raw(_ value: [String: Any]?, session: String? = nil, method: String = "POST", headers: [String: String] = [:], path: String = "/mcp") async throws -> (Int, [String: Any], HTTPURLResponse) {
            var req = URLRequest(url: URL(string: http.baseURL + path)!); req.httpMethod = method
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if let value { req.httpBody = try JSONSerialization.data(withJSONObject: value); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
            for (k,v) in headers { req.setValue(v, forHTTPHeaderField:k) }
            let (data, response) = try await network.data(for:req); let res = response as! HTTPURLResponse
            return (res.statusCode, (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:], res)
        }
        func initialize(_ version: String = "2025-06-18") async throws -> (String, [String: Any]) {
            let r = try await raw(["jsonrpc":"2.0","id":1,"method":"initialize","params":["protocolVersion":version,"clientInfo":["name":"legacy-json-fixture","version":"1"],"capabilities":[:]]])
            try check(r.0 == 200,"JSON initialization returns 200 for \(version)")
            return (r.2.value(forHTTPHeaderField:"Mcp-Session-Id")!,r.1["result"] as! [String:Any])
        }
        func call(_ name:String,id:Int,session:String?,args:[String:Any] = [:]) async throws -> (Int,[String:Any],HTTPURLResponse) {
            try await raw(["jsonrpc":"2.0","id":id,"method":"tools/call","params":["name":name,"arguments":args]],session:session)
        }
        for version in ["2024-11-05","2025-03-26","2025-06-18"] {
            let r = try await initialize(version); try check(r.1["protocolVersion"] as? String == version,"supported revision preserved \(version)")
        }
        let unknown = try await initialize("2099-01-01")
        try check(unknown.1["protocolVersion"] as? String == Version.latest,"unknown revision follows SDK negotiation")
        let (a,_) = try await initialize(), (b,_) = try await initialize()
        try check(a != b && mcp.sessions.session(a)?.engaged == false,"initialize is distinct and unengaged")
        _ = try await call("set_session_name",id:2,session:a,args:["name":"alpha"])
        try check(mcp.sessions.session(a)?.name == "alpha" && mcp.sessions.session(a)?.engaged == false,"naming stays invisible")
        let listed = try await raw(["jsonrpc":"2.0","id":3,"method":"tools/list"],session:a)
        let tools = (listed.1["result"] as? [String:Any])?["tools"] as? [[String:Any]] ?? []
        try check(tools.count == 20 && Set(tools.compactMap { $0["name"] as? String }).count == 20,"15 preserved and 5 captured tools listed")
        try check(mcp.authorizeCapturedRead == nil,"external captured authority defaults unconnected")
        let pendingA = Task { try await call("wait_for_message",id:41,session:a) }
        let pendingB = Task { try await call("wait_for_message",id:41,session:b) }
        try await until { inbox.hasWaiter(exactSession:a) && inbox.hasWaiter(exactSession:b) }
        let status = try await raw(nil,method:"GET",path:"/api/tts/status")
        try check(status.1["tts"] as? String == "ready","held calls do not block TTS")
        let duplicate = try await call("check_messages",id:41,session:a)
        try check(duplicate.0 == 409,"duplicate active ID cannot overwrite SDK waiter")
        let cancel = try await raw(["jsonrpc":"2.0","method":"notifications/cancelled","params":["requestId":41,"reason":"fixture"]],session:a)
        try check(cancel.0 == 202,"SDK accepts cancellation notification")
        let cancelled = try await pendingA.value
        try check((cancelled.1["result"] as? [String:Any])?["isError"] as? Bool == true,"cancellation releases held HTTP call")
        try check(inbox.hasWaiter(exactSession:b),"same request ID in other session remains waiting")
        inbox.add(text:"B only",attachments:[],session:b)
        let delivered = try await pendingB.value
        try check(String(describing:delivered.1).contains("B only"),"targeted wait receives correct message")
        inbox.add(text:"A retained",attachments:[],session:a)
        let retained = try await call("check_messages",id:42,session:a)
        try check(String(describing:retained.1).contains("A retained"),"cancelled waiter cannot consume later message")
        // Deterministic cancellation AFTER the queue has removed a message and
        // BEFORE the native handler returns. Both SDK and app post-checks must
        // preserve this committed result, including the immediate wait path.
        for (offset, kind) in ["immediate", "parked", "check"].enumerated() {
            let requestID = 100 + offset
            let text = "consumed-\(kind)"
            if kind != "parked" { inbox.add(text: text, attachments: [], session: a) }
            let consuming = Task { try await call(kind == "check" ? "check_messages" : "wait_for_message", id: requestID, session: a, args: ["pause_after_drain": true]) }
            if kind == "parked" {
                try await until { inbox.hasWaiter(exactSession: a) }
                inbox.add(text: text, attachments: [], session: a)
            }
            try await until { afterDrain.wait(timeout: .now()) == .success }
            _ = try await raw(["jsonrpc":"2.0", "method":"notifications/cancelled", "params":["requestId":requestID]], session:a)
            // SDK's receive loop awaits notification handlers before accepting
            // the later ping. Its response is a deterministic processing barrier.
            let barrier = try await raw(["jsonrpc":"2.0", "id":200+offset, "method":"ping"], session:a)
            try check(barrier.0 == 200, "SDK processed late cancel before result release: \(kind)")
            releaseResult.signal()
            let completed = try await consuming.value
            try check((completed.1["result"] as? [String:Any])?["isError"] as? Bool == false && String(describing:completed.1).contains(text), "consumption wins late cancellation: \(kind)")
            try check(inbox.pendingCount(for: a) == 0, "successful \(kind) response does not duplicate consumed message")
        }
        for (offset, kind) in ["immediate", "parked", "check"].enumerated() {
            let requestID = 110 + offset
            var original: InboxMessage?
            inbox.onAdded = { original = $0 }
            if kind != "parked" { inbox.add(text: "preserved-\(kind)", attachments: ["synthetic-attachment"], session: a) }
            let consuming = Task { try await call(kind == "check" ? "check_messages" : "wait_for_message", id:requestID, session:a, args:["pause_before_claim":true]) }
            if kind == "parked" {
                try await until { inbox.hasWaiter(exactSession:a) }
                inbox.add(text:"preserved-\(kind)",attachments:["synthetic-attachment"],session:a)
            }
            try await until { beforeClaim.wait(timeout:.now()) == .success }
            _ = try await raw(["jsonrpc":"2.0","method":"notifications/cancelled","params":["requestId":requestID]],session:a)
            try await until { cancelledAtClaim.wait(timeout:.now()) == .success }
            releaseClaim.signal()
            let refused = try await consuming.value
            try check((refused.1["result"] as? [String:Any])?["isError"] as? Bool == true, "cancellation wins before consumption: \(kind)")
            let queued = inbox.drain(session:a)
            try check(queued.count == 1 && queued[0].id == original?.id && queued[0].time == original?.time && queued[0].attachments == original?.attachments, "cancel-before-claim preserves exact message id/time/attachments: \(kind)")
            inbox.onAdded = nil
        }
        let asking = Task { try await call("report_to_user",id:43,session:a,args:["question":"fixture"]) }
        try await until { questionStarted.wait(timeout:.now()) == .success }
        _ = try await raw(["jsonrpc":"2.0","method":"notifications/cancelled","params":["requestId":43]],session:a)
        let answer = try await asking.value
        try check((answer.1["result"] as? [String:Any])?["isError"] as? Bool == true,"four-hour question releases on cancellation")
        let deleting = Task { try await call("wait_for_message",id:44,session:a) }
        try await until { inbox.hasWaiter(exactSession:a) }
        let deleted = try await raw(nil,session:a,method:"DELETE")
        try check(deleted.0 == 200 && mcp.sessions.session(a) == nil,"DELETE closes exact voice identity")
        _ = try await deleting.value
        try await until { !inbox.hasWaiter(exactSession:a) }
        let refreshed = try await call("report_to_user",id:45,session:a)
        try check(refreshed.0 == 200 && mcp.sessions.session(a)?.id == a,"old client ID re-adopts after DELETE")
        _ = try await call("report_to_user",id:46,session:nil)
        try check(mcp.sessions.session(MCPServer.anonymousSessionId)?.engaged == true,"headerless calls retain anonymous voice target")
        let rejected = try await raw(["jsonrpc":"2.0","id":47,"method":"ping"],session:b,headers:["Origin":"https://untrusted.invalid"])
        try check(rejected.0 == 403,"SDK rejects hostile Origin")
        let bad = try await raw(["jsonrpc":"1.0","id":48,"method":"ping"],session:b)
        try check(bad.0 == 400,"malformed ID-bearing RPC fails without hanging")
        let get = try await raw(nil,session:b,method:"GET")
        try check(get.0 == 405,"JSON endpoint visibly rejects SSE GET")
        for (path,args,key) in [("set",["voice":"nova"],"voice"),("speak",["text":"hello"],"text"),("seek",["position":2],"position"),("stop",[:],"stopped")] as [(String,[String:Any],String)] {
            let r = try await raw(args,path:"/api/tts/"+path); try check(r.0 == 200 && r.1[key] != nil,"preserved TTS \(path) route")
        }
        try check(MCPOverlayScope.owns(["session":a],sessionID:a) && !MCPOverlayScope.owns(["session":a],sessionID:b),"overlay ownership is exact-session")
        try check(!MCPOverlayScope.owns(["session":a,"system":true],sessionID:a) && !MCPOverlayScope.owns([:],sessionID:a),"system/user marks excluded from agent scope")
        let sdkClient = Client(name:"official-swift-proof",version:"1")
        let sdkTransport = HTTPClientTransport(endpoint:endpoint,streaming:false)
        let sdkInit = try await sdkClient.connect(transport:sdkTransport)
        try check(sdkInit.serverInfo.name == "voice-flow","official SDK client initializes production route")
        let sdkTools = try await sdkClient.listTools()
        try check(sdkTools.tools.count == 20,"official SDK client decodes catalog")
        _ = try await sdkClient.callTool(name:"report_to_user",arguments:["summary":.string("synthetic fixture")])
        let sdkSession = await sdkTransport.sessionID!
        let sdkWait = try await sdkClient.send(CallTool.request(.init(name: "wait_for_message")))
        try await until { inbox.hasWaiter(exactSession: sdkSession) }
        try await sdkClient.cancelRequest(sdkWait.requestID, reason: "official client cancellation")
        do { _ = try await sdkWait.value; throw Failure(text: "SDK cancellation should throw") }
        catch is CancellationError { try check(true, "official SDK client observes cancellation") }
        try await until { !inbox.hasWaiter(exactSession: sdkSession) }
        let disconnectedWait = try await sdkClient.send(CallTool.request(.init(name: "wait_for_message")))
        try await until { inbox.hasWaiter(exactSession: sdkSession) }
        await sdkClient.disconnect()
        _ = try? await disconnectedWait.value
        try await until { !inbox.hasWaiter(exactSession: sdkSession) }
        try check(true, "socket disconnect releases native waiter without DELETE")
        let afterDisconnect = try await call("check_messages", id: 52, session: sdkSession)
        try check(afterDisconnect.0 == 200, "refreshed JSON client retains session after disconnect")
        let deleteOrigin = try await raw(nil, session: b, method: "DELETE", headers: ["Origin":"https://untrusted.invalid"])
        try check(deleteOrigin.0 == 403 && mcp.sessions.session(b) != nil, "hostile origin cannot DELETE another session")
        await sdkClient.disconnect(); await mcp.stop(); http.stop()
        print("PASS native MCP production transport proof complete")
    }
}
