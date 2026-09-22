import Foundation

enum AgentSecretPolicy {
    private static let expressions: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        try! NSRegularExpression(pattern: #"(?i)\b(?:api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*['\"]?[A-Za-z0-9_./+=-]{12,}"#),
        try! NSRegularExpression(pattern: #"\b(?:sk|pk|rk)-(?:live-)?[A-Za-z0-9_-]{16,}"#),
        try! NSRegularExpression(pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#),
    ]

    static func containsSecret(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expressions.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    static func redacted(_ text: String) -> String {
        var result = text
        for expression in expressions.reversed() {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: "[REDACTED]")
        }
        return result
    }
}
