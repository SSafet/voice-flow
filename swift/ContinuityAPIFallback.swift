import Foundation

/// App-owned, tool-free routing request using the saved assistant API provider.
/// Configured by App so focused tests never need Keychain or UserSettings.
enum ContinuityAPIFallback {
    struct Configuration {
        let key: String?
        let baseURL: URL
        let model: String
    }
    static var configuration: () -> Configuration = {
        Configuration(key: nil, baseURL: URL(string: "https://openrouter.ai/api/v1")!, model: "")
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)

    static func request(prompt: String, instructions: String, config: Configuration) throws -> URLRequest {
        guard let key = config.key, !key.isEmpty else { throw Failure(message: "Assistant API key is unavailable") }
        guard !config.model.isEmpty else { throw Failure(message: "Assistant API model is unavailable") }
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": config.model, "stream": false, "max_tokens": 512,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_schema", "json_schema": [
                "name": "continuity", "strict": true,
                "schema": AssistantContinuityClassifier.responseSchema
            ]]
        ])
        return request
    }

    static func run(_ prompt: String, config: Configuration? = nil,
                    transport: Transport = send) async throws -> String {
        let config = config ?? configuration()
        let request = try request(prompt: prompt,
            instructions: AssistantContinuityClassifier.config.instructions, config: config)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = (object?["error"] as? [String: Any])?["message"] as? String ?? "request failed"
            let redacted = detail.replacingOccurrences(of: config.key ?? "", with: "[redacted]")
            throw Failure(message: "Assistant API HTTP \(response.statusCode): \(redacted.suffix(400))")
        }
        guard data.count < 100_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, !content.isEmpty else {
            throw Failure(message: "Assistant API returned no routing decision")
        }
        return content
    }

    private static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure(message: "Assistant API returned no HTTP response") }
        return (data, response)
    }
}
