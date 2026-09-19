import Foundation

// V7 — shared verification support (06 §3.13, §3.14).
//
// This file is part of the verification commit and is never edited by the
// implementer. It holds the two things every V7 suite needs: a tiny assertion
// helper in the repository's style, and the boundary double that stands where
// the operating system stands (screen, microphone, panels, notifications).
// Nothing here is the code under test: the tests assert what the bridge did
// with a host that merely records what it was asked.

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message) (actual=\(actual), expected=\(expected))\n", stderr)
        exit(1)
    }
}

func expectNil<T>(_ actual: T?, _ message: String) {
    guard actual == nil else {
        fputs("FAIL: \(message) (actual=\(String(describing: actual)))\n", stderr)
        exit(1)
    }
}

/// Reads the shell-bridge contract fixtures by name from `contract-fixtures/`.
/// The harness and `check.sh` both run with the repository root as the working
/// directory, so the path is stable.
enum ShellFixtures {
    static let folder = "contract-fixtures/shell-bridge"

    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(folder)
            .appendingPathComponent("\(name).json")
    }

    private struct RawFile: Decodable { let type: String; let examples: [ShellJSON] }

    /// One JSON line per example object, exactly the shape the shell receives
    /// or sends on the wire.
    static func rawLines(_ name: String) throws -> [String] {
        let data = try Data(contentsOf: url(name))
        let file = try JSONDecoder().decode(RawFile.self, from: data)
        return try file.examples.map { example in
            String(decoding: try example.encoded(), as: UTF8.self)
        }
    }

    static func lines<T: Decodable>(_ type: T.Type, _ name: String) throws -> [T] {
        try rawLines(name).map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    static func examples<T: Decodable>(_ type: T.Type, _ name: String) throws -> [T] {
        try lines(type, name)
    }

    static func shellDescriptor() throws -> TPShellDescriptor {
        let all = try examples(TPShellDescriptor.self, "ShellDescriptor")
        guard let first = all.first else { fatalError("ShellDescriptor.json has no example") }
        return first
    }
}

let allBridgeCapabilities: [TPBridgeCapability] = [
    .dictate, .captureScreen, .annotate, .speak, .notify,
    .filesPick, .filesPickFolder, .filesSave, .filesReveal,
    .permissions, .externalOpen,
]

/// The boundary double. It records every call by name, can be told to fail with
/// one named `ShellBridgeError`, and returns values whose shapes come from the
/// contract fixtures wherever a fixture exists.
final class RecordingShellHost: ShellBridgeHost {
    var capabilities: [TPBridgeCapability]
    var descriptor: TPShellDescriptor
    var calls: [String] = []
    var failure: ShellBridgeError?
    var closedCount = 0

    init(capabilities: [TPBridgeCapability] = allBridgeCapabilities,
         descriptor: TPShellDescriptor) {
        self.capabilities = capabilities
        self.descriptor = descriptor
    }

    private func record(_ name: String) throws {
        calls.append(name)
        if let failure { throw failure }
    }

    func describe() -> TPShellDescriptor { calls.append("shell.describe"); return descriptor }

    func escape() -> TPShellEscapeResult {
        calls.append("shell.escape")
        return TPShellEscapeResult(handled: escapeHandled)
    }
    var escapeHandled = false

    func token(endpointID: TPEndpointID) throws -> TPAuthTokenResult {
        try record("auth.token")
        return TPAuthTokenResult(accessToken: "at-0001", expiresAt: "2026-09-19T10:00:00.000Z")
    }

    func signIn(endpointID: TPEndpointID) throws -> TPAuthSignInResult {
        try record("auth.signIn")
        return TPAuthSignInResult(started: true)
    }

    func signOut(endpointID: TPEndpointID) throws { try record("auth.signOut") }

    func dictateStart(threadID: String?) throws -> TPDictateStartResult {
        try record("dictate.start")
        return TPDictateStartResult(captureID: "dict-0007")
    }

    func dictateStop(captureID: String) throws -> TPDictateStopResult {
        try record("dictate.stop")
        return TPDictateStopResult(text: "fix the cart button")
    }

    func captureScreen(threadID: String?) throws -> TPAttachmentResult {
        try record("capture.screen")
        return TPAttachmentResult(attachment: try Self.imageReference())
    }

    func annotateStart(threadID: String?, fromAttachmentID: String?) throws -> TPAttachmentResult {
        try record("annotate.start")
        return TPAttachmentResult(attachment: try Self.annotatedReference())
    }

    func speakStart(text: String, threadID: String) throws -> TPSpeakStartResult {
        try record("speak.start")
        return TPSpeakStartResult(playbackID: "play-0001")
    }

    func speakStop(playbackID: String) throws { try record("speak.stop") }

    func notify(threadID: String, title: String, body: String, tag: String) throws -> TPNotifyResult {
        try record("notify")
        return TPNotifyResult(shown: true)
    }

    func pickFiles(multiple: Bool, accept: [String]) throws -> TPFilesPickResult {
        try record("files.pick")
        return TPFilesPickResult(attachments: [try Self.fileReference()])
    }

    func pickFolder(purpose: String) throws -> TPFilesPickFolderResult {
        try record("files.pickFolder")
        return TPFilesPickFolderResult(name: "atika", path: "/Users/safet/repos/atika")
    }

    func saveFile(url: String, name: String) throws -> TPFilesSaveResult {
        try record("files.save")
        return TPFilesSaveResult(started: true)
    }

    func revealFile(path: String) throws { try record("files.reveal") }

    func permissionRows() throws -> TPPermissionsListResult {
        try record("permissions.list")
        return TPPermissionsListResult(rows: [
            TPPermissionRow(actionLabel: "Open Settings", detail: "Let VoiceFlow see the screen.",
                            id: "screen-recording", state: .needed, title: "Screen Recording"),
        ])
    }

    func openPermission(id: String) throws { try record("permissions.open") }

    func openExternal(url: String) throws { try record("external.open") }

    func routeChanged(path: String) throws { try record("route.changed") }

    func pinsReport(pins: [TPReportedPin]) throws { try record("pins.report") }

    func composerRefused(topic: TPComposerTopic, threadID: String?,
                         reason: TPComposerRefusalReason) throws {
        try record("composer.refuse")
    }

    func bridgeClosed() { calls.append("bridge.closed"); closedCount += 1 }

    static func imageReference() throws -> TPAttachmentReference {
        let all = try ShellFixtures.examples(TPAttachmentReference.self, "AttachmentReference")
        guard let image = all.first(where: { $0.kind == .image }) else {
            fatalError("AttachmentReference.json has no image example")
        }
        return image
    }

    static func annotatedReference() throws -> TPAttachmentReference {
        let all = try ShellFixtures.examples(TPAttachmentReference.self, "AttachmentReference")
        guard let annotated = all.first(where: { $0.kind == .annotatedScreenshot }) else {
            fatalError("AttachmentReference.json has no annotated_screenshot example")
        }
        return annotated
    }

    static func fileReference() throws -> TPAttachmentReference {
        let all = try ShellFixtures.examples(TPAttachmentReference.self, "AttachmentReference")
        guard let file = all.first else { fatalError("AttachmentReference.json is empty") }
        return file
    }
}
