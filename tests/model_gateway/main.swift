import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

guard let upstreamText = ProcessInfo.processInfo.environment["VOICE_FLOW_TEST_UPSTREAM"],
      let upstream = URL(string: upstreamText) else {
    fputs("FAIL: VOICE_FLOW_TEST_UPSTREAM is missing\n", stderr)
    exit(1)
}

let gateway = ModelGatewayServer(credentials: {
    ModelGatewayCredentialSnapshot(
        apiKey: "provider-secret", upstreamBaseURL: upstream,
        allowedModels: ["test/model"])
})
let connection = try gateway.start()
let usageSeen = DispatchSemaphore(value: 0)
var reportedUsage: AgentUsage?
ModelGatewayUsageReporter.shared.configure { usage in
    reportedUsage = usage
    usageSeen.signal()
}

func sendUsing(connection: ModelGatewayConnection,
               token: String, model: String) async -> (Int?, String) {
    var request = URLRequest(url: connection.baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.timeoutInterval = 3
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
        "model": model, "stream": true,
        "messages": [["role": "user", "content": "test"]],
    ])
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode,
                String(data: data, encoding: .utf8) ?? "")
    } catch {
        return (nil, "")
    }
}

func send(token: String, model: String) async -> (Int?, String) {
    await sendUsing(connection: connection, token: token, model: model)
}

let done = DispatchSemaphore(value: 0)
var failure: String?
Task {
    let unauthorized = await send(token: "wrong", model: "test/model")
    if unauthorized.0 != 401 { failure = "wrong capability was not rejected"; done.signal(); return }
    let denied = await send(token: connection.token, model: "other/model")
    if denied.0 != 403 { failure = "unlisted model was not rejected"; done.signal(); return }
    let allowed = await send(token: connection.token, model: "test/model")
    if allowed.0 != 200 || !allowed.1.contains("gateway ") || !allowed.1.contains("ok") {
        failure = "authorized streaming response was not proxied"
        done.signal()
        return
    }
    if usageSeen.wait(timeout: .now() + 2) != .success
        || reportedUsage?.inputTokens != 11
        || reportedUsage?.outputTokens != 7
        || reportedUsage?.costUSD != Decimal(string: "0.2") {
        failure = "stream usage was not reported"
        done.signal()
        return
    }
    gateway.stop()
    let revoked = await send(token: connection.token, model: "test/model")
    if revoked.0 != nil { failure = "stopped gateway did not revoke its token"; done.signal(); return }
    let rotated = try gateway.start()
    if rotated.token == connection.token {
        failure = "gateway restart reused its capability token"; done.signal(); return
    }
    let replay = await sendUsing(
        connection: rotated, token: connection.token, model: "test/model")
    if replay.0 != 401 {
        failure = "gateway restart accepted the previous token"; done.signal(); return
    }
    let current = await sendUsing(
        connection: rotated, token: rotated.token, model: "test/model")
    if current.0 != 200 {
        failure = "gateway restart rejected its current token"; done.signal(); return
    }
    gateway.stop()

    let limited = ModelGatewayServer(credentials: {
        ModelGatewayCredentialSnapshot(
            apiKey: "provider-secret", upstreamBaseURL: upstream,
            allowedModels: ["test/model"],
            modelOutputTokenLimits: ["test/model": 32_000],
            // Two successful lifecycle requests above settled at $0.40 in
            // the same durable daily ledger. Admit one more estimate and
            // reject the following one just above the shared $0.60 boundary
            // (the epsilon avoids binary floating-point admission drift).
            requestTimeout: 3, dailyBudgetUSD: 0.61,
            estimatedRequestCostUSD: 0.2)
    })
    let limitedConnection = try limited.start()
    let lastAllowed = await sendUsing(
        connection: limitedConnection, token: limitedConnection.token, model: "test/model")
    let overBudget = await sendUsing(
        connection: limitedConnection, token: limitedConnection.token, model: "test/model")
    limited.stop()
    if lastAllowed.0 != 200 || overBudget.0 != 429 {
        failure = "daily budget admission was not enforced: first=\(String(describing: lastAllowed.0)) second=\(String(describing: overBudget.0))"
    }
    done.signal()
}
expect(done.wait(timeout: .now() + 10) == .success, "model gateway test timed out")
if let failure { fputs("FAIL: \(failure)\n", stderr); exit(1) }
print("model gateway live tests passed")
