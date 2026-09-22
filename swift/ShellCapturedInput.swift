import Foundation

/// Adapts existing native source owners to the shell's narrow delivery lease.
/// Explicit root/service injection keeps QA and bootstrap separate from daily data.
@MainActor
final class ShellCapturedInput {
    struct PendingSource {
        let source: ShellInputSource
        let metadata: CapturedPendingDelivery?
        let label: String
    }
    let paths: VoiceFlowPaths
    let service: CapturedService
    lazy var custody = ShellInputCustody(pendingOnDisk: { [weak self] in self?.pendingCount() ?? 32 },
        load: { [weak self] id in
            guard let self else { throw ShellInputFailure.unavailable }
            let query = self.query()
            return try await Task.detached(priority: .utility) { try query.originalPicture(id: id) }.value
        }, mayRead: { [weak self] id in
            guard let self else { return false }
            return (try? self.query().sourceStatus(id: id).state) == .available
        }, persist: { [weak self] sources, metadata in
            guard let self else { throw ShellInputFailure.unavailable }
            try self.persist(metadata, sources: sources)
        }, release: { [weak self] sources, id in
            guard let self else { throw ShellInputFailure.unavailable }
            try self.release(sources, id: id)
        })

    init(paths: VoiceFlowPaths, service: CapturedService) { self.paths = paths; self.service = service }
    private func query() -> CapturedQuery {
        CapturedQuery(index: service.index, root: paths.configRoot, indexProgress: { [service] in service.progress }, mayRead: { true })
    }
    func retainAudio(deliveryId: String) throws {
        guard let id = UUID(uuidString: deliveryId) else { throw ShellInputFailure.invalid }
        try PendingAudioStore.retain(runId: id, delivery: custody.reservation(deliveryId), root: paths)
        try custody.attach(.file(PendingAudioStore.directory(root: paths).appendingPathComponent("\(id.uuidString).wav")), deliveryId: deliveryId)
    }
    func attachShot(path: String, deliveryId: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard try relative(url).hasPrefix("captures/shots/"), try relative(url).split(separator: "/").count == 3,
              let shot = ShotIngester.parse(url.lastPathComponent),
              try readMarker(source: url).deliveryId == deliveryId else { throw ShellInputFailure.invalid }
        let captureId = CapturedItemID.shot(name: shot.stamp)
        try custody.attach(.file(url), deliveryId: deliveryId, captureIds: [captureId])
        _ = try ShotIngester(index: service.index, root: paths.configRoot).ingest(fileName: url.lastPathComponent)
        return captureId
    }
    func attachBundle(_ summary: CaptureSummary, deliveryId: String) throws -> [String] {
        let directory = summary.directory.standardizedFileURL
        guard try relative(directory).hasPrefix("captures/"), try relative(directory).split(separator: "/").count == 2,
              let meta = try? readBundle(directory), meta.pendingDelivery?.deliveryId == deliveryId else { throw ShellInputFailure.invalid }
        guard meta.frames.count <= 32 else { throw ShellInputFailure.capacity }
        let captureIds = meta.frames.indices.map { CapturedItemID.bundleFrame(bundle: meta.id, index: $0 + 1) }
        try custody.attach(.bundle(directory), deliveryId: deliveryId, captureIds: captureIds)
        _ = try BundleIngester(index: service.index, root: paths.configRoot).ingest(id: meta.id)
        return captureIds
    }
    func complete(deliveryId: String, text: String, captureIds: [String], attachments: [String], capability: CaptureCapability) async throws -> ShellInput {
        let input = try await custody.complete(deliveryId, text: text, captureIds: captureIds)
        let entry = HistoryEntry(text: text, time: ISO8601DateFormatter().string(from: Date()),
            timestamp: ISO8601DateFormatter().string(from: Date()), id: deliveryId, destination: .kept,
            seen: false, capability: capability, attachments: attachments)
        try service.retainDictation(entry)
        return input
    }
    /// Bounded native recovery listing; not exposed as a library-read bridge.
    /// Malformed metadata is visible as unavailable custody and still retains data.
    func pendingSources(limit: Int = 64) -> [PendingSource] {
        let limit = min(129, max(1, limit))
        var result: [PendingSource] = []
        for relative in ["pending-audio", "captures/shots"] {
            let directory = paths.configRoot.appendingPathComponent(relative)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for marker in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where marker.lastPathComponent.hasSuffix(CapturedPendingFiles.suffix) {
                let source = URL(fileURLWithPath: String(marker.path.dropLast(CapturedPendingFiles.suffix.count)))
                result.append(.init(source: .file(source), metadata: try? readMarker(source: source), label: source.lastPathComponent))
                if result.count >= limit { return result }
            }
        }
        let captures = paths.configRoot.appendingPathComponent("captures")
        let bundles = (try? FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)) ?? []
        for directory in bundles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where directory.hasDirectoryPath && !["shots", "derived"].contains(directory.lastPathComponent) {
            let meta = try? readBundle(directory)
            if meta == nil || meta?.pendingDelivery != nil {
                result.append(.init(source: .bundle(directory), metadata: meta?.pendingDelivery, label: directory.lastPathComponent))
                if result.count >= limit { return result }
            }
        }
        return result
    }
    func recover(deliveryId: String, receiptOnly: Bool = false) async throws -> ShellInput {
        let matches = pendingSources(limit: 129).filter { $0.metadata?.deliveryId == deliveryId }
        guard let metadata = matches.compactMap(\.metadata).first(where: { $0.completedInput != nil }),
              matches.allSatisfy({ $0.metadata?.reservation == metadata.reservation }),
              let inputData = metadata.completedInput,
              let input = try? JSONDecoder().decode(ShellInput.self, from: inputData) else { throw ShellInputFailure.unavailable }
        let sources = matches.map(\.source)
        var ownedIds: [String] = []
        for source in sources {
            switch source {
            case .file(let url):
                if try relative(url).hasPrefix("captures/shots/"), try relative(url).split(separator: "/").count == 3, let shot = ShotIngester.parse(url.lastPathComponent) {
                    _ = try ShotIngester(index: service.index, root: paths.configRoot).ingest(fileName: url.lastPathComponent)
                    ownedIds.append(CapturedItemID.shot(name: shot.stamp))
                }
            case .bundle(let url):
                guard let meta = try? readBundle(url) else { throw ShellInputFailure.unavailable }
                _ = try BundleIngester(index: service.index, root: paths.configRoot).ingest(id: meta.id)
                ownedIds += meta.frames.indices.map { CapturedItemID.bundleFrame(bundle: meta.id, index: $0 + 1) }
            }
        }
        guard (receiptOnly ? Set(ownedIds).isSubset(of: Set(input.captureIds)) : Set(ownedIds) == Set(input.captureIds)),
              Set(ownedIds).count == ownedIds.count,
              matches.allSatisfy({ $0.metadata?.completedInput == nil || $0.metadata == metadata }) else { throw ShellInputFailure.invalid }
        return try await custody.restore(metadata, sources: sources, receiptOnly: receiptOnly)
    }
    private func pendingCount() -> Int {
        let sources = pendingSources(limit: 129)
        if sources.count >= 129 { return 32 }
        return Set(sources.compactMap { $0.metadata?.deliveryId }).count + sources.filter { $0.metadata == nil }.count
    }
    private func relative(_ url: URL) throws -> String {
        // Foundation directory enumeration canonicalizes /var to /private/var
        // on macOS. Accept those two representations of the configured root,
        // without resolving links inside a candidate source path. CapturedFiles
        // still opens every relative component with O_NOFOLLOW.
        let path = url.standardizedFileURL.path
        for root in [paths.configRoot.standardizedFileURL, paths.configRoot.resolvingSymlinksInPath().standardizedFileURL] {
            let prefix = root.path + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        throw ShellInputFailure.invalid
    }
    private func readMarker(source: URL) throws -> CapturedPendingDelivery {
        let data = try CapturedFiles.bytes(relative(CapturedPendingFiles.marker(for: source)), root: paths.configRoot)
        guard data.count <= 3_000_000 else { throw ShellInputFailure.invalid }
        let value = try JSONDecoder().decode(CapturedPendingDelivery.self, from: data)
        guard value.isValid else { throw ShellInputFailure.invalid }
        return value
    }
    private func readBundle(_ directory: URL) throws -> CaptureBundleMeta {
        let data = try CapturedFiles.bytes(relative(directory.appendingPathComponent("meta.json")), root: paths.configRoot)
        guard data.count <= 3_000_000 else { throw ShellInputFailure.invalid }
        let meta = try JSONDecoder().decode(CaptureBundleMeta.self, from: data)
        guard meta.id == directory.lastPathComponent, meta.pendingDelivery?.isValid != false else { throw ShellInputFailure.invalid }
        return meta
    }
    private func persist(_ metadata: CapturedPendingDelivery, sources: [ShellInputSource]) throws {
        for source in sources {
            switch source {
            case .file(let url):
                let old = try readMarker(source: url)
                guard old.deliveryId == metadata.deliveryId, old.reservation == metadata.reservation,
                      old.completedInput == nil || old == metadata else { throw ShellInputFailure.invalid }
                try CapturedPendingFiles.write(metadata, source: url)
            case .bundle(let directory):
                try CaptureStore.updatePendingDelivery(metadata, in: directory, deliveryId: metadata.deliveryId)
            }
        }
    }
    private func release(_ sources: [ShellInputSource], id: String) throws {
        var failure: Error?
        for source in sources {
            do {
                switch source {
                case .file(let url):
                    if CapturedPendingFiles.isProtected(url) { try CapturedPendingFiles.clear(source: url, deliveryId: id) }
                case .bundle(let directory):
                    guard let meta = try? readBundle(directory) else { throw ShellInputFailure.unavailable }
                    if meta.pendingDelivery != nil { try CaptureStore.updatePendingDelivery(nil, in: directory, deliveryId: id) }
                }
            } catch { failure = error }
        }
        if let failure { throw failure }
    }
}
