import Foundation

/// The native capability boundary, not another thread/environment protocol.
/// Keep web/voiceFlowShell.ts in sync. T3 owns all thread and composer data.
struct ShellComposerTarget: Codable, Equatable {
    enum Kind: String, Codable { case thread, draft }
    let environmentId: String
    let kind: Kind
    let id: String
    let composerId: String

    var isValid: Bool {
        [environmentId, id, composerId].allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 }
    }
}

struct ShellFrozenTarget: Codable, Equatable {
    let documentId: String
    let target: ShellComposerTarget
    var isValid: Bool { !documentId.isEmpty && documentId.utf8.count <= 128 && target.isValid }
}

/// Structured user marks for one exact JPEG already held by native custody.
/// No native path, draft action, or read capability crosses this boundary.
struct ShellMarkedCapture: Codable, Equatable {
    let captureId: String
    let sha256: String
    let width: Int
    let height: Int
    let marks: [TPMark]

    var isValid: Bool {
        guard !captureId.isEmpty, captureId.utf8.count <= 128,
              sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              (1...32_768).contains(width), (1...32_768).contains(height),
              width * height <= 100_000_000, !marks.isEmpty, marks.count <= 128 else { return false }
        var points = 0
        for (index, mark) in marks.enumerated() {
            guard mark.n == index + 1, (1...512).contains(mark.stroke),
                  mark.box.count == 4,
                  mark.box.allSatisfy({ (0...32_768).contains($0) }),
                  mark.box[2] > 0, mark.box[3] > 0,
                  mark.box[0] + mark.box[2] <= width,
                  mark.box[1] + mark.box[3] <= height,
                  (mark.note?.utf16.count ?? 0) <= 2_000,
                  (mark.note?.utf8.count ?? 0) <= 8_000,
                  (mark.underText?.utf16.count ?? 0) <= 200 else { return false }
            let coordinates = [mark.from, mark.to, mark.center, mark.origin].compactMap { $0 } + (mark.points ?? [])
            guard coordinates.allSatisfy({ $0.count == 2 && $0.allSatisfy { (-32_768...32_768).contains($0) } }),
                  (mark.points?.count ?? 0) <= 2_048 else { return false }
            points += mark.points?.count ?? 0
            guard points <= 8_192 else { return false }
            switch mark.kind {
            case .line, .arrow: guard mark.from != nil && mark.to != nil else { return false }
            case .pen, .highlight: guard (mark.points?.count ?? 0) >= 2 else { return false }
            case .badge: guard mark.center != nil && mark.label != nil else { return false }
            case .text: guard mark.origin != nil && mark.note != nil else { return false }
            case .rect, .ellipse: break
            }
        }
        return ((try? JSONEncoder().encode(marks).count) ?? Int.max) <= 256_000
    }
}

struct ShellInput: Codable, Equatable {
    /// Stable across unconfirmed delivery retries; the web consumer persists deduplication.
    let deliveryId: String
    let destination: ShellFrozenTarget
    let text: String
    /// Opaque native capture IDs. Never arbitrary native paths or read capabilities.
    let captureIds: [String]
    let markedCaptures: [ShellMarkedCapture]?

    init(deliveryId: String, destination: ShellFrozenTarget, text: String, captureIds: [String],
         markedCaptures: [ShellMarkedCapture]? = nil) {
        self.deliveryId = deliveryId; self.destination = destination; self.text = text
        self.captureIds = captureIds; self.markedCaptures = markedCaptures
    }

    var isValid: Bool {
        !deliveryId.isEmpty && deliveryId.utf8.count <= 128 && destination.isValid
            && text.utf8.count <= 1_048_576 && captureIds.count <= 32 && Set(captureIds).count == captureIds.count
            && captureIds.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
            && (markedCaptures?.count ?? 0) <= captureIds.count
            && Set(markedCaptures?.map(\.captureId) ?? []).count == (markedCaptures?.count ?? 0)
            && (markedCaptures ?? []).allSatisfy { captureIds.contains($0.captureId) && $0.isValid }
    }
}

struct ShellInputReceipt: Codable, Equatable {
    enum Status: String, Codable {
        case accepted
        case staleTarget = "stale-target"
        case unavailable, rejected, unconfirmed
    }
    let deliveryId: String
    let status: Status
}

enum ShellCapability: String, Codable, CaseIterable {
    case dictate, capture, speak, stopSpeaking, openNativeSettings
}

struct ShellCapabilityRequest: Codable {
    let capability: ShellCapability
    let destination: ShellFrozenTarget?
    let text: String?
}

struct ShellCapabilityReceipt: Codable {
    enum Status: String, Codable { case completed, cancelled, unavailable, rejected }
    let status: Status
}

struct ShellDescriptor: Encodable {
    let version = 1
    let documentId: String
    let capabilities: [ShellCapability]
}

enum ShellWire {
    static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
    }
}

/// Memory-only targeting: no native draft store, delayed sends or input replay.
/// The capture/dictation owner retains source bytes until the exact delivery is accepted.
struct ShellComposerBinding {
    private(set) var documentId = UUID().uuidString
    private(set) var target: ShellComposerTarget?

    mutating func invalidate() {
        documentId = UUID().uuidString
        target = nil
    }

    mutating func publish(_ next: ShellComposerTarget?, documentId: String) -> Bool {
        guard documentId == self.documentId, next?.isValid != false else { return false }
        target = next
        return true
    }

    func freeze() -> ShellFrozenTarget? {
        target.map { ShellFrozenTarget(documentId: documentId, target: $0) }
    }

    func matches(_ frozen: ShellFrozenTarget) -> Bool {
        frozen.documentId == documentId && frozen.target == target
    }
}
