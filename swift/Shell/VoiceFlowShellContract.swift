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

struct ShellInput: Codable, Equatable {
    /// Stable across unconfirmed delivery retries; the web consumer persists deduplication.
    let deliveryId: String
    let destination: ShellFrozenTarget
    let text: String
    /// Opaque native capture IDs. Never arbitrary native paths or read capabilities.
    let captureIds: [String]

    var isValid: Bool {
        !deliveryId.isEmpty && deliveryId.utf8.count <= 128 && destination.isValid
            && text.utf8.count <= 1_048_576 && captureIds.count <= 32 && Set(captureIds).count == captureIds.count
            && captureIds.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 }
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
