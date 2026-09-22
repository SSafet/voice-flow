import Foundation
import Darwin
import ImageIO
import CoreGraphics

/// Bytes, never a public URL. The caller serves them over its authenticated
/// file channel or passes them to an SDK image block.
struct CapturedPictureBytes {
    let id: String
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
}

struct CapturedSourceStatus: Codable, Equatable {
    enum State: String, Codable { case available, missing, thinned, deleted, indexedTextOnly = "indexed_text_only" }
    let id: String
    let state: State
}

struct CapturedReadStatus: Codable {
    let index: TPHealthIndex
    let recordingsAvailable: Int
    let recordingsMissing: Int
    let picturesMissing: Int
}

enum CapturedFiles {
    static let maxSourceBytes = 64_000_000
    static func validateRegion(_ region: [Int]?) throws {
        guard let r = region else { return }
        guard r.count == 4, r[0] >= 0, r[1] >= 0, r[2] > 0, r[3] > 0 else {
            throw CapturedQueryFailure(.invalidArguments, "A region must be [x, y, width, height] with a nonnegative origin and positive size.")
        }
    }
    // Resolve each component relative to a directory descriptor. Never follow
    // links, including a file swapped between validation and opening; never
    // block on FIFOs/devices. The descriptor remains bound to the opened file.
    static func withFile<T>(_ relative: String, root: URL, _ body: (Int32, Int) throws -> T) throws -> T {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CapturedQueryFailure(.pictureGone, "The source file is unavailable.")
        }
        var directory = open(root.standardizedFileURL.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw fileError() }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw fileError() }
            close(directory); directory = next
        }
        let fd = openat(directory, String(parts.last!), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw fileError() }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0, info.st_size <= maxSourceBytes else {
            throw CapturedQueryFailure(.pictureGone, "The source is unavailable or exceeds the 64 MB read limit.")
        }
        return try body(fd, Int(info.st_size))
    }
    private static func fileError() -> CapturedQueryFailure {
        errno == EACCES || errno == EPERM
            ? CapturedQueryFailure(.permissionDenied, "macOS denied access to the captured file.")
            : CapturedQueryFailure(.pictureGone, "The source file is missing or unavailable.")
    }
    static func isAvailable(_ relative: String, root: URL) -> Bool {
        (try? withFile(relative, root: root) { _, _ in true }) == true
    }
    static func bytes(_ relative: String, root: URL) throws -> Data {
        try withFile(relative, root: root) { fd, size in
            var data = Data(); data.reserveCapacity(size)
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; throw fileError() }
                guard data.count <= maxSourceBytes - count else {
                    throw CapturedQueryFailure(.pictureGone, "The source exceeds the 64 MB read limit.")
                }
                data.append(buffer, count: count)
            }
            return data
        }
    }
    static func image(_ data: Data, maxPx: Int?, region: [Int]?, byteLimit: Int?) throws -> (Data, Int, Int) {
        try validateRegion(region)
        guard maxPx == nil || (1...16_384).contains(maxPx!), byteLimit == nil || byteLimit! > 0 else {
            throw CapturedQueryFailure(.invalidArguments, "The picture size must be between 1 and 16,384 pixels.")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 32_768, h <= 32_768, Double(w) * Double(h) <= 100_000_000 else {
            throw CapturedQueryFailure(.pictureGone, "The stored picture cannot be decoded safely.")
        }
        // ImageIO creates thumbnails without decoding a full-size backing bitmap.
        // Apply orientation for the same pixel geometry the client displays.
        let dimension = region == nil ? min(maxPx ?? max(w, h), max(w, h)) : max(w, h)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: dimension,
            kCGImageSourceShouldCacheImmediately: true]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CapturedQueryFailure(.pictureGone, "The stored picture cannot be decoded.")
        }
        if let r = region {
            guard r[0] < image.width, r[1] < image.height, r[2] <= image.width - r[0], r[3] <= image.height - r[1],
                  let crop = image.cropping(to: CGRect(x: r[0], y: r[1], width: r[2], height: r[3])) else {
                throw CapturedQueryFailure(.invalidArguments, "The region is outside the stored picture.")
            }
            image = crop
        }
        var target = CGFloat(min(maxPx ?? max(image.width, image.height), max(image.width, image.height)))
        // Reuse the app's tested pixel-size encoder. Lower JPEG quality first;
        // only reduce geometry when the full-resolution crop cannot meet budget.
        while target >= 1 {
            try Task.checkCancellation()
            for quality: CGFloat in [0.85, 0.65, 0.45, 0.25] {
                if let jpeg = ImageUtils.jpeg(from: image, maxDimension: target, quality: quality), byteLimit.map({ jpeg.count <= $0 }) ?? true {
                    let scale = min(1, target / CGFloat(max(image.width, image.height)))
                    return (jpeg, max(1, Int((CGFloat(image.width) * scale).rounded())), max(1, Int((CGFloat(image.height) * scale).rounded())))
                }
            }
            if target == 1 { break }; target = max(1, floor(target * 0.75))
        }
        throw CapturedQueryFailure(.pictureGone, "The picture cannot fit the requested byte budget.")
    }
}

extension CapturedQuery {
    func picture(_ input: TPCapturedPictureParams, byteLimit: Int? = nil) throws -> CapturedPictureBytes {
        let original = try originalPicture(id: input.id, variant: input.variant)
        let (data, width, height) = try CapturedFiles.image(original, maxPx: input.maxPx, region: input.region, byteLimit: byteLimit)
        return CapturedPictureBytes(id: input.id, data: data, mimeType: "image/jpeg", width: width, height: height)
    }
    /// Original image bytes are available to the authenticated owner interface;
    /// tools use `picture(...byteLimit:400_000)` instead. No original is rewritten.
    func originalPicture(id: String, variant: TPPictureVariant? = nil) throws -> Data {
        try checkReady()
        let source = try index.read { try row($0, id: id) }
        guard source.imageState == .present, let path = variant == .clean ? source.pathClean : source.path else {
            throw CapturedQueryFailure(.pictureGone, "The requested picture is no longer available.")
        }
        return try CapturedFiles.bytes(path, root: root)
    }
    func sourceStatus(id: String) throws -> CapturedSourceStatus {
        try checkReady()
        return try index.read { db in sourceStatus(try row(db, id: id)) }
    }
    func sourceStatus(_ row: CapturedItemRow) -> CapturedSourceStatus {
        if row.kind == .recording {
            // S1 does not store a path on recordings. Its id is derived from this
            // exact file name; never infer delivered/undelivered from cached extra.
            let file = "pending-audio/" + row.id.dropFirst("recording:".count) + ".wav"
            return .init(id: row.id, state: CapturedFiles.isAvailable(file, root: root) ? .available : .missing)
        }
        if row.imageState == .thinned { return .init(id: row.id, state: .thinned) }
        if row.imageState == .missing { return .init(id: row.id, state: .missing) }
        if row.imageState == .deleted { return .init(id: row.id, state: .deleted) }
        if let path = row.path { return .init(id: row.id, state: CapturedFiles.isAvailable(path, root: root) ? .available : .missing) }
        return .init(id: row.id, state: .indexedTextOnly)
    }
    /// Query-owned facts only. Retention, watcher permissions and synchronization
    /// belong to their services and must be supplied by the full health assembler.
    func status(lastError: String? = nil) throws -> CapturedReadStatus {
        guard mayRead() else { throw CapturedQueryFailure(.permissionDenied, "Captured data requires observe access on this device.") }
        let progress = indexProgress()
        return try index.read { db in
            let all = try rows(db, where: "path IS NOT NULL OR kind = 'recording'")
            let recordings = all.filter { $0.kind == .recording }
            let available = recordings.filter { sourceStatus($0).state == .available }.count
            let pictures = all.filter { $0.path != nil }
            let missing = pictures.filter { sourceStatus($0).state == .missing }.count
            return CapturedReadStatus(index: TPHealthIndex(daysDone: progress.daysDone, daysTotal: progress.daysTotal,
                lastError: CapturedReadPolicy.text(lastError), picturesRecognised: pictures.filter { $0.ocrState == .done }.count,
                picturesTotal: pictures.count, state: TPIndexState(rawValue: progress.state.rawValue)!),
                recordingsAvailable: available, recordingsMissing: recordings.count - available, picturesMissing: missing)
        }
    }
}

extension CapturedFiles {
    /// Only disposable derived files are written. O_EXCL and no-follow directory
    /// traversal prevent a derived path from overwriting any original or symlink.
    static func writeDerived(_ data: Data, root: URL) throws -> String {
        var directory = open(root.standardizedFileURL.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw CapturedQueryFailure(.permissionDenied, "The derived picture folder is unavailable.") }
        defer { close(directory) }
        for component in ["captures", "derived"] {
            if mkdirat(directory, component, 0o700) != 0 && errno != EEXIST {
                throw CapturedQueryFailure(.permissionDenied, "The derived picture folder cannot be created.")
            }
            let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw CapturedQueryFailure(.permissionDenied, "The derived picture folder is unavailable.") }
            close(directory); directory = next
        }
        let name = "query-" + UUID().uuidString + ".jpg"
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CapturedQueryFailure(.permissionDenied, "The derived picture cannot be created.") }
        defer { close(fd) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw CapturedQueryFailure(.permissionDenied, "The derived picture cannot be written.") }
                    offset += n
                }
            }
        } catch { unlinkat(directory, name, 0); throw error }
        return root.appendingPathComponent("captures/derived/" + name).path
    }
}
