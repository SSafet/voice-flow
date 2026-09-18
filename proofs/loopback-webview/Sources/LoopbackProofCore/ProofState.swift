import Foundation
import Security

/// One row of the printed table.
public struct ProofRow: Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case check, observation }
    public let kind: Kind
    public let name: String
    public let passed: Bool?      // nil for observations
    public let detail: String
    public init(kind: Kind, name: String, passed: Bool?, detail: String) {
        self.kind = kind
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// Everything the running proof accumulates.
public actor ProofState {
    public nonisolated let secret: String
    private var tickets: [String: Bool] = [:]       // ticket -> used
    private var rows: [ProofRow] = []
    private var upgradeHeaderSeen: [String: String] = [:]   // path -> the header value, "" when absent
    private var pageReport: [ProofRow] = []
    private var reportArrived = false
    private var serverErrors: [String] = []

    public init() {
        self.secret = ProofState.randomHex(byteCount: 32)
    }

    public func mintTicket() -> String {
        let ticket = ProofState.randomHex(byteCount: 16)
        tickets[ticket] = false
        return ticket
    }

    /// True exactly once per ticket.
    public func consumeTicket(_ ticket: String) -> Bool {
        guard let used = tickets[ticket], used == false else { return false }
        tickets[ticket] = true
        return true
    }

    public func recordUpgradeHeader(path: String, value: String?) {
        upgradeHeaderSeen[path] = value ?? ""
    }

    public func upgradeHeader(path: String) -> String? { upgradeHeaderSeen[path] }

    /// Every listener that stops says so. Two listeners share one port, and the
    /// second one usually stops because the first one did, so keeping only the
    /// last message would hide the cause behind its consequence.
    public func recordServerError(_ text: String) { serverErrors.append(text) }
    public func serverErrorText() -> String? {
        serverErrors.isEmpty ? nil : serverErrors.joined(separator: "; ")
    }

    public func add(_ row: ProofRow) { rows.append(row) }
    public func addAll(_ newRows: [ProofRow]) { rows.append(contentsOf: newRows) }
    public func allRows() -> [ProofRow] { rows + pageReport }

    public func receivePageReport(_ reported: [ProofRow]) {
        pageReport = reported
        reportArrived = true
    }

    public func hasPageReport() -> Bool { reportArrived }

    /// Polls until the page has posted its table, or the deadline passes.
    public func waitForPageReport(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !reportArrived, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return reportArrived
    }

    /// The secret and the tickets are what keeps a page on another origin out, so
    /// they come from the system's random source and the program stops if it
    /// cannot be read: a predictable secret would make every guard below a
    /// pretence.
    private static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
