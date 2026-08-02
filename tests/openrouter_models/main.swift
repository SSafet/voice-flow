import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

final class CatalogProtocol: URLProtocol {
    static let lock = NSLock()
    static var responseData = Data()
    static var failure: Error?
    static var request: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.lock.withLock { () -> (Data, Error?) in
            Self.request = request
            return (Self.responseData, Self.failure)
        }
        if let failure = state.1 {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: state.0)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let fixture = """
{"data":[
  {"id":"test/tool-image","name":"Tool Image","context_length":131072,
   "top_provider":{"context_length":131072,"max_completion_tokens":16384},
   "architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},
   "pricing":{"prompt":"0.000001","completion":"0.000004"},
   "supported_parameters":["tools","tool_choice","temperature"]},
  {"id":"test/no-tools","name":"No Tools",
   "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
   "supported_parameters":["temperature"]},
  {"id":"test/image-output","name":"Image Output",
   "architecture":{"input_modalities":["text"],"output_modalities":["image"]},
   "supported_parameters":["tools"]},
  {"id":"test/tool-image","name":"Duplicate",
   "architecture":{"input_modalities":["text"],"output_modalities":["text"]},
   "supported_parameters":["tools"]}
]}
"""
CatalogProtocol.responseData = Data(fixture.utf8)
let configuration = URLSessionConfiguration.ephemeral
configuration.protocolClasses = [CatalogProtocol.self]
let session = URLSession(configuration: configuration)
let cacheURL = VoiceFlowPaths.shared.file("catalog-test.json")
let catalog = OpenRouterModelCatalog(cacheURL: cacheURL, session: session)
let canary = "sk-or-v1-CATALOG-CANARY"
let live = await catalog.refresh(
    baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: canary,
    fallbackIDs: ["test/manual"])
expect(live.source == .live, "live catalog did not report its source")
expect(live.models.map(\.id) == ["test/tool-image", "test/manual"],
       "catalog filtering/deduplication changed: \(live.models.map(\.id))")
let model = live.models.first { $0.id == "test/tool-image" }!
expect(model.supportsImages && model.supportsTools && model.hasTextOutput,
       "catalog lost agent capability metadata")
expect(model.openCodeContextLimit == 131_072 && model.openCodeOutputLimit == 16_384,
       "catalog lost OpenCode context/output limits")
expect(model.detail.replacingOccurrences(of: ",", with: "").contains("131072")
       && model.detail.contains("$1.00 / $4.00"),
       "catalog detail lost context or pricing: \(model.detail)")
let request = CatalogProtocol.lock.withLock { CatalogProtocol.request }
expect(request?.url?.path == "/api/v1/models",
       "catalog requested the wrong endpoint: \(request?.url?.absoluteString ?? "nil")")
let query = URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
expect(query.contains(URLQueryItem(name: "supported_parameters", value: "tools"))
       && query.contains(URLQueryItem(name: "output_modalities", value: "text")),
       "catalog omitted server-side compatibility filters")
expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(canary)",
       "catalog did not authenticate its transient request")
let cacheText = String(data: try Data(contentsOf: cacheURL), encoding: .utf8)!
expect(!cacheText.contains(canary),
       "catalog cache persisted the API key")

CatalogProtocol.failure = URLError(.notConnectedToInternet)
let cached = await OpenRouterModelCatalog(cacheURL: cacheURL, session: session).refresh(
    baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: canary,
    fallbackIDs: ["test/manual"])
expect(cached.source == .cache && cached.models.contains(where: { $0.id == "test/tool-image" }),
       "offline refresh did not fall back to the last valid catalog")

let emptyCacheURL = VoiceFlowPaths.shared.file("catalog-empty-test.json")
let fallback = await OpenRouterModelCatalog(cacheURL: emptyCacheURL, session: session).refresh(
    baseURL: URL(string: "https://openrouter.ai/api/v1")!, apiKey: canary,
    fallbackIDs: ["test/manual"])
expect(fallback.source == .fallback && fallback.models.map(\.id) == ["test/manual"],
       "empty offline catalog did not preserve manual/default selection")
expect(fallback.models[0].openCodeContextLimit == 128_000
       && fallback.models[0].openCodeOutputLimit == 32_000,
       "manual model fallback limits are not conservative")
print("OpenRouter model catalog tests passed")
