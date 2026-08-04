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
    static var requestCount = 0
    static var loadDelay: TimeInterval = 0

    static func hits() -> Int { lock.withLock { requestCount } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.lock.withLock { () -> (Data, Error?, TimeInterval) in
            Self.request = request
            Self.requestCount += 1
            return (Self.responseData, Self.failure, Self.loadDelay)
        }
        if state.2 > 0 { Thread.sleep(forTimeInterval: state.2) }
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

// ── Staleness gate ──────────────────────────────────────
// The catalog is only as good as its last fetch: a running app used to serve
// whatever snapshot the last Settings visit left on disk, so a model released
// afterwards was unreachable from every picker.
CatalogProtocol.lock.withLock { CatalogProtocol.failure = nil }
let apiBase = URL(string: "https://openrouter.ai/api/v1")!

let cachedRequest = CatalogProtocol.lock.withLock { CatalogProtocol.request }
expect(cachedRequest?.cachePolicy == .reloadIgnoringLocalCacheData,
       "catalog request may be answered from the URL cache while reporting live")

let freshURL = VoiceFlowPaths.shared.file("catalog-fresh-test.json")
try? FileManager.default.removeItem(at: freshURL)
let freshCatalog = OpenRouterModelCatalog(cacheURL: freshURL, session: session)
_ = await freshCatalog.refresh(baseURL: apiBase, apiKey: canary, fallbackIDs: [])
let hitsBeforeFresh = CatalogProtocol.hits()
let skipped = await freshCatalog.refreshIfStale(
    baseURL: apiBase, apiKey: canary, fallbackIDs: [], maxAge: 3600)
expect(skipped == nil, "a fresh snapshot reported a refresh it never performed")
expect(CatalogProtocol.hits() == hitsBeforeFresh,
       "a fresh snapshot still went to the provider")

let reused = freshCatalog.cachedResult(including: ["test/manual"])
expect(reused.source == .cache && reused.fetchedAt != nil,
       "cachedResult lost the snapshot timestamp")
expect(reused.models.contains { $0.id == "test/manual" },
       "cachedResult dropped the manually pinned model ID")
expect(!reused.statusText.contains("refresh unavailable"),
       "a deliberately reused fresh snapshot reads as a failed refresh: \(reused.statusText)")

// A day-old snapshot on disk is exactly the state that hid a newly released
// model for a full day.
let agedURL = VoiceFlowPaths.shared.file("catalog-aged-test.json")
let agedAt = Date().addingTimeInterval(-24 * 3600).timeIntervalSinceReferenceDate
let agedCache = """
{"fetchedAt":\(agedAt),"models":[{"id":"test/yesterday","name":"Yesterday",
 "inputModalities":["text"],"outputModalities":["text"],
 "supportedParameters":["tools"]}]}
"""
try Data(agedCache.utf8).write(to: agedURL)
let agedCatalog = OpenRouterModelCatalog(cacheURL: agedURL, session: session)
let renewed = await agedCatalog.refreshIfStale(
    baseURL: apiBase, apiKey: canary, fallbackIDs: [])
expect(renewed?.source == .live,
       "a day-old snapshot was served instead of refreshed")
expect(renewed?.models.contains { $0.id == "test/tool-image" } == true,
       "the refreshed catalog did not reach the caller")

// Launch, Settings and the automation editor can all ask at once.
CatalogProtocol.lock.withLock { CatalogProtocol.loadDelay = 0.15 }
let raceURL = VoiceFlowPaths.shared.file("catalog-race-test.json")
try? FileManager.default.removeItem(at: raceURL)
let raceCatalog = OpenRouterModelCatalog(cacheURL: raceURL, session: session)
let hitsBeforeRace = CatalogProtocol.hits()
async let firstCaller = raceCatalog.refreshIfStale(
    baseURL: apiBase, apiKey: canary, fallbackIDs: ["test/manual"], maxAge: 0)
async let secondCaller = raceCatalog.refreshIfStale(
    baseURL: apiBase, apiKey: canary, fallbackIDs: [], maxAge: 0)
let racers = await (firstCaller, secondCaller)
CatalogProtocol.lock.withLock { CatalogProtocol.loadDelay = 0 }
expect(CatalogProtocol.hits() - hitsBeforeRace == 1,
       "concurrent refreshes stampeded the provider: \(CatalogProtocol.hits() - hitsBeforeRace) requests")
expect(racers.0?.models.contains { $0.id == "test/tool-image" } == true
       && racers.1?.models.contains { $0.id == "test/tool-image" } == true,
       "a joined refresh returned no catalog")
expect(racers.0?.models.contains { $0.id == "test/manual" } == true,
       "the joining caller lost its own pinned model ID")

print("OpenRouter model catalog tests passed")
