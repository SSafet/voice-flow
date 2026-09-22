import Foundation
import Darwin

/// A native source publishes only after its bytes are committed. The root
/// keeps isolated/test stores from refreshing the daily app's derived index.
enum CapturedSourceEvents {
    static let committed = Notification.Name("voiceflow.captured.source-committed")

    static func didCommit(root: URL = VoiceFlowPaths.shared.configRoot) {
        NotificationCenter.default.post(name: committed, object: root.standardizedFileURL)
    }
}

/// Custody metadata belongs beside an existing native source. The shell's exact
/// reservation/completed payload is opaque here; source retention never decodes
/// it into permission to read or send. A malformed marker still protects bytes.
struct CapturedPendingDelivery: Codable, Equatable {
    let version: Int
    let deliveryId: String
    let reservation: Data
    let completedInput: Data?
    let pictures: [CapturedDeliveryPicture]

    init(deliveryId: String, reservation: Data, completedInput: Data? = nil,
         pictures: [CapturedDeliveryPicture] = []) {
        version = 1; self.deliveryId = deliveryId; self.reservation = reservation
        self.completedInput = completedInput; self.pictures = pictures
    }

    var isValid: Bool {
        version == 1 && UUID(uuidString: deliveryId) != nil && !reservation.isEmpty && reservation.count <= 16_384
            && (completedInput?.count ?? 0) <= 2_097_152 && pictures.count <= 32
            && Set(pictures.map(\.captureId)).count == pictures.count
            && pictures.allSatisfy(\.isValid)
    }
}

struct CapturedDeliveryPicture: Codable, Equatable {
    let captureId: String
    let name: String
    let mimeType: String
    let sizeBytes: Int
    let sha256: String
    var isValid: Bool {
        !captureId.isEmpty && captureId.utf8.count <= 128 && !name.isEmpty && name.utf8.count <= 256
            && !name.contains("/") && !name.contains("\\") && sizeBytes > 0 && sizeBytes <= 64_000_000
            && ["image/jpeg", "image/png", "image/webp", "image/gif", "image/heic", "image/tiff"].contains(mimeType)
            && sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
}

/// Per-file custody, never one marker that grants an entire directory. Bundle
/// custody lives in CaptureBundleMeta.pendingDelivery instead. Only native
/// source owners call this with URLs; the web contract accepts opaque IDs only.
enum CapturedPendingFiles {
    static let suffix = ".pending-delivery.json"
    static func marker(for source: URL) -> URL { URL(fileURLWithPath: source.path + suffix) }
    static func isProtected(_ source: URL) -> Bool {
        var info = stat()
        // Including dangling symlinks and access failures: only proven absence
        // authorizes ordinary pruning.
        return lstat(marker(for: source).path, &info) == 0 || errno != ENOENT
    }
    static func read(source: URL) throws -> CapturedPendingDelivery {
        let fd = open(marker(for: source).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 3_000_000 else { throw CocoaError(.fileReadCorruptFile) }
        let data = try handle.read(upToCount: 3_000_001) ?? Data()
        guard data.count == info.st_size else { throw CocoaError(.fileReadCorruptFile) }
        let value = try JSONDecoder().decode(CapturedPendingDelivery.self, from: data)
        guard value.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    static func write(_ value: CapturedPendingDelivery, source: URL) throws {
        guard value.isValid else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = marker(for: source)
        if isProtected(source) {
            let old = try read(source: source)
            guard old.deliveryId == value.deliveryId, old.reservation == value.reservation,
                  old.completedInput == nil || old == value else { throw CocoaError(.fileWriteNoPermission) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    /// A failed removal leaves custody in place for explicit reconciliation.
    static func clear(source: URL, deliveryId: String) throws {
        let value = try read(source: source)
        guard value.deliveryId == deliveryId else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.removeItem(at: marker(for: source))
    }
}
