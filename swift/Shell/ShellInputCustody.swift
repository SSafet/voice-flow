import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ShellCaptureReadRequest: Codable {
    let deliveryId: String
    let captureId: String
    let offset: Int
    let maxBytes: Int
}
struct ShellCaptureReadReply: Codable {
    let captureId: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
    let sha256: String
    let offset: Int
    let base64: String
}

/// Native-only source references. No bridge method accepts or returns these.
enum ShellInputSource: Equatable {
    case file(URL)
    case bundle(URL)
}

enum ShellInputFailure: Error { case unavailable, invalid, staleTarget, capacity, changedSource }

/// Bounded custody of input already collected by native services. Source stores
/// persist provenance; T3 owns the draft and receipt. This is neither a draft
/// store nor a send queue: nothing retries, retargets or executes automatically.
@MainActor
final class ShellInputCustody {
    typealias Load = (String) async throws -> Data
    typealias Persist = ([ShellInputSource], CapturedPendingDelivery) throws -> Void
    private struct Entry {
        let destination: ShellFrozenTarget
        var sources: [ShellInputSource] = []
        var captureIds: Set<String> = []
        var input: ShellInput?
        var pictures: [String: (CapturedDeliveryPicture, Data)] = [:]
        var completing = false
    }
    private var entries: [String: Entry] = [:]
    private var preparing = false
    private let load: Load
    private let mayRead: (String) -> Bool
    private let persist: Persist
    private let release: ([ShellInputSource], String) throws -> Void
    private let pendingOnDisk: () -> Int
    let maxPending: Int
    let maxCachedBytes: Int
    var pendingIds: [String] { entries.keys.sorted() }
    var cachedBytes: Int { entries.values.reduce(0) { $0 + $1.pictures.values.reduce(0) { $0 + $1.1.count } } }

    init(maxPending: Int = 32, maxCachedBytes: Int = 128_000_000,
         pendingOnDisk: @escaping () -> Int = { 0 }, load: @escaping Load,
         mayRead: @escaping (String) -> Bool, persist: @escaping Persist,
         release: @escaping ([ShellInputSource], String) throws -> Void) {
        self.maxPending = maxPending; self.maxCachedBytes = maxCachedBytes
        self.pendingOnDisk = pendingOnDisk; self.load = load; self.mayRead = mayRead
        self.persist = persist; self.release = release
    }

    func reserve(_ destination: ShellFrozenTarget, deliveryId: String = UUID().uuidString) throws -> String {
        guard destination.isValid, UUID(uuidString: deliveryId) != nil,
              entries[deliveryId] == nil else { throw ShellInputFailure.invalid }
        guard entries.count < maxPending, pendingOnDisk() < maxPending else { throw ShellInputFailure.capacity }
        entries[deliveryId] = Entry(destination: destination)
        return deliveryId
    }
    func reservation(_ id: String) throws -> CapturedPendingDelivery {
        guard let entry = entries[id] else { throw ShellInputFailure.unavailable }
        return CapturedPendingDelivery(deliveryId: id, reservation: try Self.encode(entry.destination))
    }
    func destination(_ id: String) -> ShellFrozenTarget? { entries[id]?.destination }
    func input(_ id: String) -> ShellInput? { entries[id]?.input }
    func owns(_ input: ShellInput) -> Bool { entries[input.deliveryId]?.input == input }
    func attach(_ source: ShellInputSource, deliveryId: String, captureIds: [String] = []) throws {
        guard var entry = entries[deliveryId], entry.input == nil, !entry.completing else { throw ShellInputFailure.invalid }
        guard captureIds.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              Set(captureIds).count == captureIds.count,
              entry.captureIds.union(captureIds).count <= 32 else { throw ShellInputFailure.invalid }
        if !entry.sources.contains(source) { entry.sources.append(source) }
        entry.captureIds.formUnion(captureIds)
        entries[deliveryId] = entry
    }
    /// Safe only before any source was produced; never evict unconfirmed custody.
    func abandonEmpty(_ id: String) { if entries[id]?.sources.isEmpty == true { entries.removeValue(forKey: id) } }

    func complete(_ id: String, text: String, captureIds: [String]) async throws -> ShellInput {
        guard var entry = entries[id], !entry.completing, !entry.sources.isEmpty else { throw ShellInputFailure.unavailable }
        let input = ShellInput(deliveryId: id, destination: entry.destination, text: text, captureIds: captureIds)
        guard input.isValid, !text.isEmpty || !captureIds.isEmpty, Set(captureIds).count == captureIds.count,
              Set(captureIds) == entry.captureIds else { throw ShellInputFailure.invalid }
        if let old = entry.input { guard old == input else { throw ShellInputFailure.invalid }; return old }
        // At most one read preparation; no parallel unaccounted byte buffers or
        // implicit wait/replay queue. A busy caller retains its source to retry.
        guard !preparing else { throw ShellInputFailure.unavailable }
        preparing = true; entry.completing = true; entries[id] = entry
        defer { preparing = false; entries[id]?.completing = false }
        let pictures = try await snapshots(captureIds)
        let metadata = CapturedPendingDelivery(deliveryId: id, reservation: try Self.encode(entry.destination),
            completedInput: try Self.encode(input), pictures: captureIds.compactMap { pictures[$0]?.0 })
        try persist(entry.sources, metadata) // fail closed before first attempted web mutation
        entries[id]?.pictures = pictures; entries[id]?.input = input
        return input
    }

    /// Explicit recovery only. Native reads the exact source's metadata, never
    /// scans/replays all inputs into a newly mounted composer. Every source hash
    /// must still match before the old delivery gains byte capability.
    func restore(_ metadata: CapturedPendingDelivery, sources: [ShellInputSource], receiptOnly: Bool = false) async throws -> ShellInput {
        guard metadata.isValid, !sources.isEmpty, let encoded = metadata.completedInput,
              let input = try? JSONDecoder().decode(ShellInput.self, from: encoded), input.isValid,
              input.deliveryId == metadata.deliveryId,
              (try? JSONDecoder().decode(ShellFrozenTarget.self, from: metadata.reservation)) == input.destination,
              Set(input.captureIds) == Set(metadata.pictures.map(\.captureId)),
              input.captureIds.count == metadata.pictures.count else { throw ShellInputFailure.invalid }
        if let old = entries[input.deliveryId]?.input { guard old == input else { throw ShellInputFailure.invalid }; return old }
        if let existing = entries[input.deliveryId] {
            guard existing.destination == input.destination, !existing.completing else { throw ShellInputFailure.invalid }
        }
        guard entries.count < maxPending || entries[input.deliveryId] != nil else { throw ShellInputFailure.capacity }
        guard !preparing else { throw ShellInputFailure.unavailable }
        preparing = true
        defer { preparing = false }
        let pictures = try await snapshots(input.captureIds)
        for saved in metadata.pictures {
            guard pictures[saved.captureId]?.0 == saved else { throw ShellInputFailure.changedSource }
        }
        entries[input.deliveryId] = Entry(destination: input.destination, sources: sources, captureIds: Set(input.captureIds), input: input, pictures: receiptOnly ? [:] : pictures)
        return input
    }

    func read(_ request: ShellCaptureReadRequest, binding: ShellComposerBinding) throws -> ShellCaptureReadReply {
        guard let entry = entries[request.deliveryId], let input = entry.input,
              input.captureIds.contains(request.captureId) else { throw ShellInputFailure.unavailable }
        guard binding.matches(entry.destination) else { throw ShellInputFailure.staleTarget }
        guard mayRead(request.captureId) else { throw ShellInputFailure.unavailable }
        guard let (metadata, bytes) = entry.pictures[request.captureId], request.offset >= 0,
              request.offset <= bytes.count, (1...524_288).contains(request.maxBytes) else { throw ShellInputFailure.invalid }
        let end = request.offset + min(request.maxBytes, bytes.count - request.offset)
        return ShellCaptureReadReply(captureId: metadata.captureId, name: metadata.name, mimeType: metadata.mimeType,
            sizeBytes: metadata.sizeBytes, sha256: metadata.sha256, offset: request.offset,
            base64: bytes.subdata(in: request.offset..<end).base64EncodedString())
    }
    @discardableResult
    func acknowledge(_ receipt: ShellInputReceipt) -> Bool {
        guard receipt.status == .accepted, let entry = entries[receipt.deliveryId], entry.input != nil else { return false }
        do { try release(entry.sources, receipt.deliveryId) }
        catch { return false } // retain custody; the same receipt can reconcile cleanup later
        entries.removeValue(forKey: receipt.deliveryId)
        return true
    }

    private func snapshots(_ ids: [String]) async throws -> [String: (CapturedDeliveryPicture, Data)] {
        var result: [String: (CapturedDeliveryPicture, Data)] = [:]
        var total = 0
        for id in ids {
            guard mayRead(id) else { throw ShellInputFailure.unavailable }
            let bytes = try await load(id)
            guard mayRead(id), bytes.count <= 64_000_000,
                  bytes.count <= maxCachedBytes - cachedBytes - total else { throw ShellInputFailure.capacity }
            let metadata = try Self.picture(id: id, bytes: bytes)
            total += bytes.count; result[id] = (metadata, bytes)
        }
        return result
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func picture(id: String, bytes: Data) throws -> CapturedDeliveryPicture {
        guard !bytes.isEmpty, let image = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(image), let type = UTType(identifier as String),
              let mime = type.preferredMIMEType, let ext = type.preferredFilenameExtension,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32_768, height <= 32_768,
              Double(width) * Double(height) <= 100_000_000 else { throw ShellInputFailure.invalid }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let value = CapturedDeliveryPicture(captureId: id, name: "capture-\(digest.prefix(12)).\(ext)",
            mimeType: mime, sizeBytes: bytes.count, sha256: digest)
        guard value.isValid else { throw ShellInputFailure.invalid }
        return value
    }
}
