import Foundation

/// Typed read-only collection. No shell, executable plugin, browser control, or mailbox write path.
final class SourceCollector {
    let store: DataSourceStore
    private var timer: Timer?
    private let lock = NSRecursiveLock()
    private struct CollectionRun {
        let token: UUID
        let completion: ((String?) -> Void)?
    }
    private var active: [String: CollectionRun] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 2; queue.qualityOfService = .utility; return queue
    }()
    init(store: DataSourceStore) { self.store = store }
    deinit { timer?.invalidate(); queue.cancelAllOperations() }
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshDue() }
        refreshDue()
    }
    func stop() {
        timer?.invalidate(); timer = nil
        lock.lock(); defer { lock.unlock() }
        for (id, run) in active {
            store.failCollection(sourceID: id, error: "Collection stopped; saved copies are still available.")
            DispatchQueue.main.async { run.completion?("Collection cancelled.") }
        }
        active.removeAll()
        // Cancelled queued operations never execute their blocks, so stop owns
        // their completion; running blocks use the token to avoid a second call.
        queue.cancelAllOperations()
    }
    func pause(sourceID: String, paused: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard var definition = store.source(id: sourceID) else { throw DataSourceError.invalid("Source was removed.") }
        definition.enabled = !paused
        try store.save(definition)
        if paused {
            if let run = active.removeValue(forKey: sourceID) {
                store.failCollection(sourceID: sourceID, error: "Collection paused; saved copies are still available.")
                DispatchQueue.main.async { run.completion?("Collection cancelled.") }
            }
        } else { refresh(sourceID: sourceID) }
    }
    private func refreshDue() {
        store.pruneExpiredSnapshots()
        for source in store.listSources() where source.enabled {
            let status = store.status(sourceID: source.id)
            if !status.refreshing && (status.nextRefresh == nil || status.nextRefresh! <= Date()) { refresh(sourceID: source.id) }
        }
    }
    func refresh(sourceID: String, completion: ((String?) -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let definition = store.source(id: sourceID) else { completion?("Source was removed."); return }
        guard active[sourceID] == nil else { completion?("Collection is already running."); return }
        let token = UUID(); active[sourceID] = CollectionRun(token: token, completion: completion)
        store.beginCollection(sourceID: sourceID)
        queue.addOperation { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let shouldCollect = self.active[sourceID]?.token == token
            self.lock.unlock()
            guard shouldCollect else { return }
            do {
                let result = try Self.collect(definition, root: self.store.root)
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.active[sourceID]?.token == token else { return }
                guard self.store.source(id: sourceID)?.location == definition.location else { throw DataSourceError.invalid("Connection changed during collection; refresh again.") }
                try self.store.commitCollection(sourceID: sourceID, result: result)
                self.active.removeValue(forKey: sourceID)
                DispatchQueue.main.async { completion?(nil) }
            } catch {
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.active[sourceID]?.token == token else { return }
                self.active.removeValue(forKey: sourceID)
                let errorText = error.localizedDescription
                self.store.failCollection(sourceID: sourceID, error: errorText)
                DispatchQueue.main.async { completion?(errorText) }
            }
        }
    }

    static let maxFileBytes = 2_000_000
    static let maxTotalBytes = 12_000_000
    static let maxItems = 200

    static func collect(_ source: SourceDefinition, root: URL) throws -> SourceCollectionResult {
        switch source.kind {
        case .website:
            guard let url = URL(string: source.location), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { throw DataSourceError.invalid("Invalid website URL.") }
            let fetched = try SourceHTTPFetch.fetch(url)
            guard let text = decodeText(fetched.0) else { throw DataSourceError.invalid("The website response is not readable text. Use a text, HTML, or JSON URL.") }
            let html = fetched.1.contains("html") || text.lowercased().contains("<html")
            let content = html ? htmlText(text) : text
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DataSourceError.invalid("The website returned no readable content.") }
            return SourceCollectionResult(documents: [CollectedSourceDocument(title: source.name, text: content, original: fetched.0, originalExtension: html ? "html" : "txt")])
        case .localFolder, .emailCopies:
            return try collectFolder(source)
        case .dictations:
            let entries = try jsonArray(root.appendingPathComponent("dictations.json"))
            return SourceCollectionResult(documents: entries.prefix(maxItems).compactMap { entry in
                guard let text = entry["text"] as? String else { return nil }
                let stamp = entry["timestamp"] as? String ?? entry["time"] as? String ?? "Date unavailable"
                return CollectedSourceDocument(title: "Dictation · \(stamp)", text: text, capturedAt: parseDate(entry["timestamp"]) ?? Date())
            }, skippedCount: max(0, entries.count - maxItems))
        case .assistantHistory:
            let path = root.appendingPathComponent("assistant-sessions.json")
            guard FileManager.default.fileExists(atPath: path.path) else { return SourceCollectionResult(documents: []) }
            guard let json = try JSONSerialization.jsonObject(with: boundedRead(path, maximum: 20_000_000)) as? [String: Any],
                  let entries = json["sessions"] as? [[String: Any]] else { throw DataSourceError.invalid("Assistant history has an unsupported or unreadable format.") }
            let sorted = entries.sorted { (parseDate($0["updatedAt"]) ?? .distantPast) > (parseDate($1["updatedAt"]) ?? .distantPast) }
            return SourceCollectionResult(documents: sorted.prefix(50).map { entry in
                let messages = entry["messages"] as? [[String: Any]] ?? []
                let text = messages.suffix(100).map { "\($0["role"] as? String ?? "message"): \($0["text"] as? String ?? "")" }.joined(separator: "\n\n")
                return CollectedSourceDocument(title: entry["title"] as? String ?? "Conversation", text: String(text.prefix(100000)), capturedAt: parseDate(entry["updatedAt"]) ?? Date())
            }, skippedCount: max(0, sorted.count - 50))
        case .captures:
            let folder = root.appendingPathComponent("captures")
            guard FileManager.default.fileExists(atPath: folder.path) else { return SourceCollectionResult(documents: []) }
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent > $1.lastPathComponent }
            var documents: [CollectedSourceDocument] = []
            for url in urls.prefix(60) {
                let metadata = url.appendingPathComponent("meta.json")
                guard FileManager.default.fileExists(atPath: metadata.path) else { continue }
                let data = try boundedRead(metadata)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let transcript = json["transcript"] as? String else { throw DataSourceError.invalid("Capture metadata could not be read: \(url.lastPathComponent).") }
                let frames = json["frames"] as? [[String: Any]] ?? []
                let summary = "\(transcript)\n\n\(frames.count) captured frames. Original bundle: \(url.path)"
                documents.append(CollectedSourceDocument(title: json["id"] as? String ?? url.lastPathComponent, text: summary, capturedAt: parseDate(json["endedAt"]) ?? Date()))
            }
            return SourceCollectionResult(documents: documents)
        case .desktop:
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            let folder = root.appendingPathComponent("watcher").appendingPathComponent(formatter.string(from: Date()))
            var documents: [CollectedSourceDocument] = []
            for stream in ["activity", "actions"] {
                let url = folder.appendingPathComponent("\(stream).jsonl")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                // Tail from disk, bounded even after a long recording day.
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let size = try handle.seekToEnd(); let start = size > 200000 ? size - 200000 : 0
                // Include the preceding byte so a cut exactly at a record boundary keeps
                // that record. Discard the partial record as bytes before decoding UTF-8.
                let readStart = start > 0 ? start - 1 : 0
                try handle.seek(toOffset: readStart)
                var data = try handle.read(upToCount: Int(size - readStart)) ?? Data()
                if start > 0 {
                    if let newline = data.firstIndex(of: 10) { data = Data(data.suffix(from: data.index(after: newline))) }
                    else { data = Data() }
                }
                // DayBus appends newline-terminated records. A concurrent append may
                // expose an unfinished final record, including half a UTF-8 scalar.
                if let newline = data.lastIndex(of: 10) { data = Data(data.prefix(through: newline)) }
                else { data = Data() }
                guard let text = String(data: data, encoding: .utf8) else { throw DataSourceError.invalid("Desktop \(stream) log contains unreadable text.") }
                let lines = text.split(separator: "\n").map(String.init)
                let recent = Array(lines.suffix(100))
                if !recent.isEmpty {
                    let lastEvent = recent.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                    let recordedAt = (lastEvent?["e"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
                    documents.append(CollectedSourceDocument(title: "Today · \(stream) · latest \(recent.count) events", text: recent.joined(separator: "\n"), capturedAt: recordedAt))
                }
            }
            return SourceCollectionResult(documents: documents)
        }
    }

    private static func collectFolder(_ source: SourceDefinition) throws -> SourceCollectionResult {
        let folder = URL(fileURLWithPath: source.location, isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw DataSourceError.invalid("The selected folder is unavailable.") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw DataSourceError.invalid("The selected folder cannot be read.") }
        let allowed = source.kind == .emailCopies ? Set(["eml", "mbox"]) : Set(["txt", "md", "json", "csv", "tsv", "log", "html", "htm", "xml", "yaml", "yml", "swift", "py", "js", "ts", "css"])
        var documents: [CollectedSourceDocument] = [], skipped = 0, bytes = 0, scanned = 0
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > 5000 { skipped += 1; break }
            if enumerator.level > 5 { enumerator.skipDescendants(); skipped += 1; continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); skipped += 1; continue }
            guard values?.isRegularFile == true else { continue }
            guard allowed.contains(url.pathExtension.lowercased()), documents.count < maxItems, (values?.fileSize ?? Int.max) <= maxFileBytes, bytes + (values?.fileSize ?? Int.max) <= maxTotalBytes else { skipped += 1; continue }
            guard url.resolvingSymlinksInPath().path.hasPrefix(folder.path + "/"), let data = try? boundedRead(url), let text = decodeText(data) else { skipped += 1; continue }
            bytes += data.count
            let date = values?.contentModificationDate ?? Date()
            if source.kind == .emailCopies {
                let messages = url.pathExtension.lowercased() == "mbox" ? SourceMailParser.splitMbox(text) : [text]
                for message in messages {
                    guard documents.count < maxItems else { skipped += 1; continue }
                    let parsed = SourceMailParser.parse(message)
                    documents.append(CollectedSourceDocument(title: parsed.title, text: parsed.text, original: Data(message.utf8), originalExtension: "eml", capturedAt: date))
                }
            } else {
                let html = ["html", "htm"].contains(url.pathExtension.lowercased())
                documents.append(CollectedSourceDocument(title: String(url.path.dropFirst(folder.path.count + 1)), text: html ? htmlText(text) : text, original: data, originalExtension: url.pathExtension, capturedAt: date))
            }
        }
        return SourceCollectionResult(documents: documents, skippedCount: skipped)
    }

    private static func boundedRead(_ url: URL, maximum: Int = maxFileBytes) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw DataSourceError.invalid("The source file exceeds the \(maximum)-byte collection limit.") }
        return data
    }
    private static func jsonArray(_ url: URL) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let items = try JSONSerialization.jsonObject(with: boundedRead(url, maximum: 20_000_000)) as? [[String: Any]] else { throw DataSourceError.invalid("The saved source has an unsupported format.") }
        return items
    }
    private static func parseDate(_ value: Any?) -> Date? {
        if let number = value as? Double { return Date(timeIntervalSinceReferenceDate: number) }
        if let text = value as? String {
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: text)
        }
        return nil
    }
    static func decodeText(_ data: Data) -> String? {
        if data.prefix(1000).contains(0) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
    static func htmlText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style|noscript)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)<(?:br|/p|/div|/li|/h[1-6])\\b[^>]*>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: replacement) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class SourceHTTPFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var bytes = Data()
    private var failure: Error?
    private var contentType = ""
    static func fetch(_ url: URL) throws -> (Data, String) {
        let delegate = SourceHTTPFetch()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("VoiceFlow-SourceCollector/1", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
        guard delegate.semaphore.wait(timeout: .now() + 27) == .success else { throw DataSourceError.invalid("Website collection timed out after 25 seconds.") }
        if let failure = delegate.failure { throw failure }
        return (delegate.bytes, delegate.contentType)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            failure = DataSourceError.invalid("Website returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0). Last good copy is preserved.")
            completionHandler(.cancel); return
        }
        contentType = response.mimeType ?? ""
        if response.expectedContentLength > SourceCollector.maxFileBytes {
            failure = DataSourceError.invalid("Website response exceeds the 2 MB limit."); completionHandler(.cancel); return
        }
        if !contentType.isEmpty && !contentType.hasPrefix("text/") && !["application/json", "application/xml", "application/xhtml+xml"].contains(contentType) {
            failure = DataSourceError.invalid("Website response is \(contentType); a text, HTML, or JSON URL is required."); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= SourceCollector.maxFileBytes else { failure = DataSourceError.invalid("Website response exceeds the 2 MB limit."); dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil { failure = error }; semaphore.signal()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { failure = DataSourceError.invalid("Website redirected to an unsupported URL."); completionHandler(nil); return }
        completionHandler(request)
    }
}

/// Export-only MIME reader. Attachments remain in the original copy; only text bodies enter context.
enum SourceMailParser {
    static func splitMbox(_ text: String) -> [String] {
        var messages: [String] = [], current: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.hasPrefix("From ") {
                if !current.isEmpty { messages.append(current.joined(separator: "\n")); current = [] }
            } else { current.append(line.hasPrefix(">From ") ? String(line.dropFirst()) : line) }
        }
        if !current.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { messages.append(current.joined(separator: "\n")) }
        return messages
    }
    static func parse(_ raw: String) -> (title: String, text: String) {
        let (headers, _) = split(raw)
        let subject = decodeHeader(headers["subject"] ?? "Email without subject")
        let metadata = ["From", "To", "Date", "Subject"].compactMap { key in headers[key.lowercased()].map { "\(key): \(decodeHeader($0))" } }.joined(separator: "\n")
        return (subject, metadata + "\n\n" + body(raw, depth: 0))
    }
    private static func split(_ raw: String) -> ([String: String], String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let boundary = normalized.range(of: "\n\n") else { return ([:], normalized) }
        let header = String(normalized[..<boundary.lowerBound]).replacingOccurrences(of: "\n[ \\t]+", with: " ", options: .regularExpression)
        var fields: [String: String] = [:]
        for line in header.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return (fields, String(normalized[boundary.upperBound...]))
    }
    private static func body(_ raw: String, depth: Int) -> String {
        guard depth < 10 else { return "[Nested email content omitted: depth limit]" }
        let (headers, content) = split(raw)
        let type = headers["content-type"] ?? "text/plain"
        if (headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return "" }
        if type.lowercased().hasPrefix("multipart/"), let regex = try? NSRegularExpression(pattern: "(?i)boundary\\s*=\\s*(?:\"([^\"]+)\"|([^;\\s]+))"), let match = regex.firstMatch(in: type, range: NSRange(type.startIndex..., in: type)) {
            let capture = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            if let range = Range(capture, in: type) {
                let marker = "--" + type[range]
                let parts = content.components(separatedBy: marker).dropFirst().filter { !$0.hasPrefix("--") }.map { $0.trimmingCharacters(in: .newlines) }
                let texts = parts.map { body($0, depth: depth + 1) }.filter { !$0.isEmpty }
                return type.lowercased().hasPrefix("multipart/alternative") ? (texts.first ?? "") : texts.joined(separator: "\n\n")
            }
        }
        guard type.lowercased().hasPrefix("text/") else { return "" }
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        var text = content
        if encoding == "base64", let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) { text = SourceCollector.decodeText(data) ?? "[Unreadable email body]" }
        if encoding == "quoted-printable" { text = SourceCollector.decodeText(quotedPrintable(content)) ?? content }
        return type.lowercased().hasPrefix("text/html") ? SourceCollector.htmlText(text) : text
    }
    private static func quotedPrintable(_ text: String) -> Data {
        let bytes = Array(text.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "").utf8)
        var result = Data(), index = 0
        while index < bytes.count {
            if bytes[index] == 61, index + 2 < bytes.count, let hex = String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii), let value = UInt8(hex, radix: 16) { result.append(value); index += 3 }
            else { result.append(bytes[index]); index += 1 }
        }
        return result
    }
    private static func decodeHeader(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([bBqQ])\\?([^?]*)\\?=") else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let encodingRange = Range(match.range(at: 2), in: text), let contentRange = Range(match.range(at: 3), in: text) else { continue }
            let content = String(text[contentRange])
            let data = text[encodingRange].lowercased() == "b" ? Data(base64Encoded: content) : quotedPrintable(content.replacingOccurrences(of: "_", with: " "))
            if let data, let decoded = SourceCollector.decodeText(data) { result.replaceSubrange(whole, with: decoded) }
        }
        return result
    }
}
