import Foundation

struct OpenRouterModel: Codable, Equatable {
    let id: String
    let name: String
    let contextLength: Int?
    let maxCompletionTokens: Int?
    let inputModalities: [String]
    let outputModalities: [String]
    let promptPrice: String?
    let completionPrice: String?
    let supportedParameters: [String]

    var supportsTools: Bool { supportedParameters.contains("tools") }
    var supportsImages: Bool { inputModalities.contains("image") }
    var hasTextOutput: Bool { outputModalities.contains("text") }

    /// OpenCode needs these limits for context accounting because Voice Flow
    /// presents OpenRouter through a private custom provider. Catalog values
    /// win; conservative fallbacks keep offline/manual IDs usable.
    var openCodeContextLimit: Int {
        min(max(contextLength ?? 128_000, 4_096), 2_000_000)
    }

    var openCodeOutputLimit: Int {
        let providerLimit = maxCompletionTokens ?? min(openCodeContextLimit, 32_000)
        return min(max(providerLimit, 256), min(openCodeContextLimit, 128_000))
    }

    var displayLabel: String {
        name == id ? id : "\(name) — \(id)"
    }

    var detail: String {
        var parts: [String] = []
        if let contextLength {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            parts.append("\(formatter.string(from: NSNumber(value: contextLength)) ?? String(contextLength)) context")
        }
        parts.append(supportsImages ? "text + images" : "text")
        if let prompt = Self.perMillion(promptPrice),
           let completion = Self.perMillion(completionPrice) {
            parts.append(String(format: "$%.2f / $%.2f per 1M", prompt, completion))
        }
        return parts.joined(separator: " · ")
    }

    static func fallback(id: String) -> OpenRouterModel {
        OpenRouterModel(
            id: id, name: id, contextLength: nil, maxCompletionTokens: nil,
            inputModalities: ["text", "image"], outputModalities: ["text"],
            promptPrice: nil, completionPrice: nil,
            supportedParameters: ["tools"])
    }

    private static func perMillion(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw), value >= 0 else { return nil }
        return value * 1_000_000
    }
}

enum OpenRouterModelCatalogSource: String, Equatable {
    case live
    case cache
    case fallback
}

struct OpenRouterModelCatalogResult: Equatable {
    let models: [OpenRouterModel]
    let source: OpenRouterModelCatalogSource
    let fetchedAt: Date?
    let warning: String?

    var statusText: String {
        switch source {
        case .live:
            return "\(models.count) tool-capable OpenRouter models · updated now"
        case .cache where warning == nil:
            // A deliberately reused fresh snapshot, not a failed refresh.
            return "\(models.count) tool-capable OpenRouter models · updated \(Self.age(fetchedAt))"
        case .cache:
            return "\(models.count) cached OpenRouter models · refresh unavailable"
        case .fallback:
            return "OpenRouter list unavailable · type an exact model ID"
        }
    }

    private static func age(_ fetchedAt: Date?) -> String {
        guard let fetchedAt else { return "earlier" }
        let minutes = Int(Date().timeIntervalSince(fetchedAt) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

enum OpenRouterModelCatalogError: LocalizedError {
    case invalidResponse
    case status(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "OpenRouter returned an invalid models response."
        case .status(let code): return "OpenRouter models request returned HTTP \(code)."
        case .empty: return "OpenRouter returned no tool-capable text models."
        }
    }
}

/// Provider catalog used by both the automation picker and the private model
/// gateway. The cache intentionally contains metadata only; credentials stay
/// in Keychain and are applied to the transient request header.
final class OpenRouterModelCatalog {
    static let shared = OpenRouterModelCatalog()

    private struct Cache: Codable {
        let fetchedAt: Date
        let models: [OpenRouterModel]
    }

    private struct APIResponse: Decodable {
        struct APIModel: Decodable {
            struct Architecture: Decodable {
                let inputModalities: [String]?
                let outputModalities: [String]?

                enum CodingKeys: String, CodingKey {
                    case inputModalities = "input_modalities"
                    case outputModalities = "output_modalities"
                }
            }

            struct Pricing: Decodable {
                let prompt: String?
                let completion: String?
            }

            struct TopProvider: Decodable {
                let contextLength: Int?
                let maxCompletionTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case contextLength = "context_length"
                    case maxCompletionTokens = "max_completion_tokens"
                }
            }

            let id: String
            let name: String?
            let contextLength: Int?
            let architecture: Architecture?
            let pricing: Pricing?
            let topProvider: TopProvider?
            let supportedParameters: [String]?

            enum CodingKeys: String, CodingKey {
                case id, name, architecture, pricing
                case contextLength = "context_length"
                case topProvider = "top_provider"
                case supportedParameters = "supported_parameters"
            }
        }

        let data: [APIModel]
    }

    /// How long a snapshot is served before `refreshIfStale` goes back to the
    /// network. Providers add models daily, so a day-old list is a stale list.
    static let defaultMaxAge: TimeInterval = 6 * 3600

    private let lock = NSLock()
    private let cacheURL: URL
    private let session: URLSession
    private var memoryCache: Cache?
    private var inFlight: Task<OpenRouterModelCatalogResult, Never>?

    init(cacheURL: URL = VoiceFlowPaths.shared.file("openrouter-models.json"),
         session: URLSession = .shared) {
        self.cacheURL = cacheURL
        self.session = session
    }

    func cachedModels(including fallbackIDs: Set<String> = []) -> [OpenRouterModel] {
        let cached = lock.withLock { loadCacheLocked()?.models ?? [] }
        return Self.merging(cached, fallbackIDs: fallbackIDs)
    }

    /// The last stored snapshot as a result, so a surface that skipped the
    /// network still renders a populated picker with an honest status line.
    func cachedResult(including fallbackIDs: Set<String> = [])
        -> OpenRouterModelCatalogResult {
        let cached = lock.withLock { loadCacheLocked() }
        guard let cached, !cached.models.isEmpty else {
            return OpenRouterModelCatalogResult(
                models: Self.merging([], fallbackIDs: fallbackIDs),
                source: .fallback, fetchedAt: nil, warning: nil)
        }
        return OpenRouterModelCatalogResult(
            models: Self.merging(cached.models, fallbackIDs: fallbackIDs),
            source: .cache, fetchedAt: cached.fetchedAt, warning: nil)
    }

    /// Refresh only when the stored snapshot has aged out, and only once when
    /// several surfaces ask at the same moment. Returns nil when the cache was
    /// still fresh, so callers can skip a redundant UI update.
    func refreshIfStale(baseURL: URL, apiKey: String?, fallbackIDs: Set<String>,
                        maxAge: TimeInterval = defaultMaxAge) async
        -> OpenRouterModelCatalogResult? {
        enum Plan {
            case fresh
            case join(Task<OpenRouterModelCatalogResult, Never>)
            case start(Task<OpenRouterModelCatalogResult, Never>)
        }

        let plan: Plan = lock.withLock {
            if let inFlight { return .join(inFlight) }
            if let cached = loadCacheLocked(), !cached.models.isEmpty,
               Date().timeIntervalSince(cached.fetchedAt) < maxAge {
                return .fresh
            }
            let task = Task {
                await self.refresh(
                    baseURL: baseURL, apiKey: apiKey, fallbackIDs: fallbackIDs)
            }
            inFlight = task
            return .start(task)
        }

        switch plan {
        case .fresh:
            return nil
        case .start(let task):
            let result = await task.value
            lock.withLock { inFlight = nil }
            return result
        case .join(let task):
            // Someone else's fallback IDs shaped that result; re-merge ours.
            let result = await task.value
            return OpenRouterModelCatalogResult(
                models: Self.merging(result.models, fallbackIDs: fallbackIDs),
                source: result.source, fetchedAt: result.fetchedAt,
                warning: result.warning)
        }
    }

    func refresh(baseURL: URL, apiKey: String?, fallbackIDs: Set<String>) async
        -> OpenRouterModelCatalogResult {
        do {
            let request = try Self.request(baseURL: baseURL, apiKey: apiKey)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenRouterModelCatalogError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw OpenRouterModelCatalogError.status(http.statusCode)
            }
            let decoded = try Self.decodeModels(data)
            guard !decoded.isEmpty else { throw OpenRouterModelCatalogError.empty }
            let cache = Cache(fetchedAt: Date(), models: decoded)
            lock.withLock { saveCacheLocked(cache) }
            return OpenRouterModelCatalogResult(
                models: Self.merging(decoded, fallbackIDs: fallbackIDs),
                source: .live, fetchedAt: cache.fetchedAt, warning: nil)
        } catch {
            let cached = lock.withLock { loadCacheLocked() }
            if let cached, !cached.models.isEmpty {
                return OpenRouterModelCatalogResult(
                    models: Self.merging(cached.models, fallbackIDs: fallbackIDs),
                    source: .cache, fetchedAt: cached.fetchedAt,
                    warning: error.localizedDescription)
            }
            return OpenRouterModelCatalogResult(
                models: Self.merging([], fallbackIDs: fallbackIDs),
                source: .fallback, fetchedAt: nil,
                warning: error.localizedDescription)
        }
    }

    static func decodeModels(_ data: Data) throws -> [OpenRouterModel] {
        let response = try JSONDecoder().decode(APIResponse.self, from: data)
        let models = response.data.compactMap { item -> OpenRouterModel? in
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return nil }
            let parameters = item.supportedParameters ?? []
            let outputs = item.architecture?.outputModalities ?? []
            guard parameters.contains("tools"), outputs.contains("text") else { return nil }
            return OpenRouterModel(
                id: id,
                name: item.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? id,
                contextLength: item.topProvider?.contextLength ?? item.contextLength,
                maxCompletionTokens: item.topProvider?.maxCompletionTokens,
                inputModalities: item.architecture?.inputModalities ?? ["text"],
                outputModalities: outputs,
                promptPrice: item.pricing?.prompt,
                completionPrice: item.pricing?.completion,
                supportedParameters: parameters)
        }
        return merging(models, fallbackIDs: [])
    }

    private static func request(baseURL: URL, apiKey: String?) throws -> URLRequest {
        var modelsURL = baseURL
        if modelsURL.lastPathComponent != "models" {
            modelsURL.appendPathComponent("models")
        }
        guard var components = URLComponents(url: modelsURL, resolvingAgainstBaseURL: false) else {
            throw OpenRouterModelCatalogError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "supported_parameters", value: "tools"),
            URLQueryItem(name: "output_modalities", value: "text"),
            URLQueryItem(name: "sort", value: "most-popular"),
        ]
        guard let url = components.url else { throw OpenRouterModelCatalogError.invalidResponse }
        // OpenRouter serves the catalog with `max-age=300,
        // stale-while-revalidate=3600`, so the default protocol policy would
        // hand back an hour-old body while we reported it as freshly live.
        var request = URLRequest(
            url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func merging(_ models: [OpenRouterModel], fallbackIDs: Set<String>)
        -> [OpenRouterModel] {
        var seen: Set<String> = []
        var result: [OpenRouterModel] = []
        for model in models where seen.insert(model.id).inserted {
            result.append(model)
        }
        for id in fallbackIDs.sorted() {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, seen.insert(trimmed).inserted {
                result.append(.fallback(id: trimmed))
            }
        }
        return result
    }

    private func loadCacheLocked() -> Cache? {
        if let memoryCache { return memoryCache }
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(Cache.self, from: data),
              !decoded.models.isEmpty else { return nil }
        memoryCache = decoded
        return decoded
    }

    private func saveCacheLocked(_ cache: Cache) {
        memoryCache = cache
        guard let data = try? JSONEncoder().encode(cache) else { return }
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            vflog("OpenRouter model cache write failed: \(error.localizedDescription)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
