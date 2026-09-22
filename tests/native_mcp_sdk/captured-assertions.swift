let sdkReply = MCPCapturedReader.read(.get, arguments: ["id":"shot:s", "region":[20,10,20,20]], service: service)
expect(!sdkReply.isError && sdkReply.content.count == 2, "production MCP reader emits text and image")
let sdkRoundTrip = try JSONDecoder().decode(MCP.CallTool.Result.self, from: JSONEncoder().encode(sdkReply.sdkResult))
expect(sdkRoundTrip.structuredContent != nil && sdkRoundTrip.isError == false, "SDK round-trip preserves structured captured result")
if case .image(let encoded, let mime, _, let meta) = sdkRoundTrip.content[1] {
    expect(mime == "image/jpeg" && Data(base64Encoded: encoded)!.count <= 400_000, "SDK image MIME and byte limit")
    expect(meta?["ai.atika/captureId"]?.stringValue == "shot:s" && meta?["width"] == .int(20) && meta?["height"] == .int(20), "SDK image metadata binds capture id and decoded crop geometry")
} else { expect(false, "SDK result contains image block") }
let hinted = sdkReply.appending("\nVoice messages queued.").sdkResult
expect(hinted.structuredContent == sdkRoundTrip.structuredContent && hinted.content.count == 3, "message/name hints preserve structured result and image blocks")
let deniedService = CapturedReadService(query: CapturedQuery(index: index, root: root))
let deniedSDK = MCPCapturedReader.read(.get, arguments: ["id":"shot:s"], service: deniedService)
expect(deniedSDK.isError && deniedSDK.content.count == 1 && deniedSDK.text.contains("permission_denied"), "default-deny query cannot release captured picture through MCP")
var grantChecks = 0
let revokedService = CapturedReadService(query: CapturedQuery(index: index, root: root, mayRead: {
    grantChecks += 1
    return grantChecks < 3
}))
let revokedSDK = MCPCapturedReader.read(.get, arguments: ["id":"shot:s"], service: revokedService)
expect(grantChecks >= 3 && revokedSDK.isError && revokedSDK.content.count == 1, "grant revoked between metadata and image returns no image")
let pemSDK = MCPCapturedReader.read(.get, arguments: ["id":"dictation:pem"], service: service)
expect(!pemSDK.text.contains("SYNTHETICPEMBODY") && !pemSDK.text.contains("QUJD") && !pemSDK.text.contains("PRIVATE KEY"), "production MCP captured reply keeps full-key redaction")
// Exercise the actual host/callback adapter, including unconnected and wrong-peer
// authority. This fixture grants one synthetic session, never any real user data.
let capturedHost = MCPServer()
capturedHost.callTool = { operation, arguments, session, cancellation in
    capturedHost.readCaptured(CapturedReadOperation(rawValue: operation)!, arguments: arguments,
        session: session, cancellation: cancellation, index: index, root: root,
        progress: { CapturedProgress(state: .ready, daysDone: 1, daysTotal: 1) })
}
let capturedDone = DispatchSemaphore(value: 0)
Task.detached {
    defer { capturedDone.signal() }
    do {
        func callCaptured(_ session: String, _ args: [String: Any]) async throws -> MCP.CallTool.Result {
            let data = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":100, "method":"tools/call",
                                                                  "params":["name":"captured_get","arguments":args]])
            let reply = await capturedHost.handleHTTP(method: "POST", headers: ["Mcp-Session-Id":session,"Accept":"application/json","Content-Type":"application/json"], body:data)
            return try JSONDecoder().decode(MCP.Response<MCP.CallTool>.self, from: reply.bodyData!).result.get()
        }
        let disconnected = try await callCaptured("synthetic-a", ["id":"shot:s"])
        expect(disconnected.isError == true && String(describing: disconnected.content).contains("captured_access_unconnected"), "captured host returns explicit unconnected authority")
        capturedHost.authorizeCapturedRead = { $0.id == "synthetic-a" }
        let wrong = try await callCaptured("synthetic-b", ["id":"shot:s", "threadId":"synthetic-a", "_meta":["grant":true]])
        expect(wrong.isError == true && wrong.content.count == 1, "client-provided thread/grant claims cannot authorize another peer")
        let granted = try await callCaptured("synthetic-a", ["id":"shot:s"])
        expect(granted.isError == false && granted.content.count == 2 && granted.structuredContent != nil, "granted captured read travels through SDK host and production query")
        capturedHost.authorizeCapturedRead = { _ in false }
        let withdrawn = try await callCaptured("synthetic-a", ["id":"shot:s"])
        expect(withdrawn.isError == true && withdrawn.content.count == 1, "same peer loses image access after authority withdrawal")
        await capturedHost.stop()
    } catch { expect(false, "captured host proof: \(error)") }
}
expect(capturedDone.wait(timeout: .now() + 10) == .success, "captured SDK host proof finishes within deadline")
