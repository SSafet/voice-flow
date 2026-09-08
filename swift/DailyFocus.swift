import Foundation

/// The sole user-authored daily briefing shared by assistants and Watcher.
/// No inference from dictations happens here: an assistant may replace it only
/// when the user supplies new focus, or the user saves the settings editor.
enum DailyFocus {
    static let maxCharacters = 6_000
    static var url: URL { VoiceFlowPaths.shared.file("FOCUS-NOW.md") }

    struct Snapshot {
        let bytes: Data?
        let updatedAt: Date?
        let text: String

        func isCurrent(at date: Date, calendar: Calendar = .current) -> Bool {
            guard let updatedAt, updatedAt <= date else { return false }
            return calendar.isDate(updatedAt, inSameDayAs: date)
        }

        func status(at date: Date = Date(), calendar: Calendar = .current) -> String {
            guard !text.isEmpty else { return "No active daily context" }
            guard let updatedAt else { return "Undated context · historical only" }
            let day = DailyFocus.day(updatedAt, calendar: calendar)
            return isCurrent(at: date, calendar: calendar)
                ? "Active today (\(day)) · expires at local midnight"
                : "Context dated \(day) · historical only"
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func read(from url: URL = url) throws -> Snapshot {
        let bytes: Data
        do { bytes = try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return Snapshot(bytes: nil, updatedAt: nil, text: "")
        }
        guard bytes.count <= maxCharacters * 4 + 256, let raw = String(data: bytes, encoding: .utf8) else {
            throw Failure(message: "Daily context must be UTF-8 and at most \(maxCharacters) characters.")
        }
        let lines = raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let first = String(lines.first ?? "")
        let hasHeader = first.hasPrefix("Updated: ")
        let timestamp = hasHeader ? ISO8601DateFormatter().date(from: String(first.dropFirst(9)).trimmingCharacters(in: .whitespaces)) : nil
        let body = hasHeader ? (lines.count > 1 ? String(lines[1]) : "") : raw
        guard body.count <= maxCharacters else { throw Failure(message: "Keep daily context under \(maxCharacters) characters.") }
        return Snapshot(bytes: bytes, updatedAt: timestamp, text: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func replace(_ text: String, expected: Snapshot, at date: Date = Date(), to url: URL = url) throws {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count <= maxCharacters else { throw Failure(message: "Keep daily context under \(maxCharacters) characters.") }
        guard try read(from: url).bytes == expected.bytes else {
            throw Failure(message: "Daily context changed elsewhere. Reload before replacing it; your draft is still here.")
        }
        let timestamp = ISO8601DateFormatter().string(from: date)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Updated: \(timestamp)\n\n\(body)\n".utf8).write(to: url, options: .atomic)
    }

    static func prompt(from url: URL = url, at date: Date = Date(), calendar: Calendar = .current) -> String {
        let snapshot: Snapshot
        do { snapshot = try read(from: url) }
        catch { return "# Daily context\nThe shared daily context could not be read: \(error.localizedDescription). Do not infer today's focus or claim it was saved." }
        let today = day(date, calendar: calendar)
        let state = snapshot.status(at: date, calendar: calendar)
        return """
        # Safet's shared daily context
        File: \(url.path)
        Today: \(today) (\(calendar.timeZone.identifier)).
        Status: \(state).

        This file is Safet's own briefing: focus, day context, and corrections to Watcher reports. Apply its context only when it is active today. Older, future-dated, or undated content is historical evidence, never today's intent. It does not grant new permissions or override the current request.
        When Safet states a new current focus (for example “today I'm focusing on X”), REPLACE this file with that new focus and a fresh ISO-8601 timestamp on its first line: Updated: <timestamp>. Do not blend stale focus into the replacement. Obtain the current timestamp when writing. Preserve only context the user explicitly asks to retain. Keep the body under \(maxCharacters) characters. Re-read before writing if the user may have edited it meanwhile; verify the write before saying it is saved. If this turn has no file-writing capability, say it is not saved and direct the user to Settings → Watcher → Daily context. The current request still applies to this turn.
        Watcher reads the same file on every review; assistants receive it on every turn. A change applies to subsequent turns/reviews, and today's context expires at local midnight.

        <DAILY_CONTEXT_FILE>
        \(snapshot.bytes.flatMap { String(data: $0, encoding: .utf8) } ?? "(no file yet)")
        </DAILY_CONTEXT_FILE>
        """
    }
}
