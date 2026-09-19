import Foundation

// The retention table and the thinning rule (07 §3.11, §3.13).
//
// S5 owns one answer to "what is kept", read by the Captures area through the
// health object and acted on by RetentionSweeper. The table and the keep-list
// are pure so the expensive parts (the files, the database) can be checked in
// the sweeper's own suite without a screen or a real archive.

private var failures: [String] = []
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do { if try !condition() { failures.append(message) } }
    catch { failures.append("\(message) — the check itself threw \(error)") }
}
private func finish(_ label: String) -> Never {
    if failures.isEmpty { print("\(label): ok"); exit(0) }
    for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
    fputs("\(label): \(failures.count) failure(s)\n", stderr)
    exit(1)
}

// ── one budget setting, one key ───────────────────────────────────────────

expect(CapturedRetentionSettings.budgetKey == "captured_pictures_budget_gb",
       "the budget setting's key is not the one of 07 §3.16")
expect(CapturedRetentionSettings.defaultPicturesBudgetGB == 25,
       "the default picture budget is not 25 GB")
expect(CapturedRetentionSettings(picturesBudgetGB: 0).picturesBudgetGB == 1,
       "a budget below the 1 GB floor was accepted")
expect(CapturedRetentionSettings(picturesBudgetGB: 501).picturesBudgetGB == 500,
       "a budget above the 500 GB ceiling was accepted")
expect(CapturedRetentionSettings(picturesBudgetGB: 25).picturesBudgetGB == 25,
       "an in-range budget was changed")
expect(CapturedRetentionSettings(picturesBudgetGB: 25).budgetBytes == 25_000_000_000,
       "the budget is not converted to bytes at 1 GB = 10^9")

// ── the per-stream table of 07 §3.11 ──────────────────────────────────────

let entries = RetentionRules.retention(budgetGB: 25)
expect(entries.count == RetentionStream.allCases.count,
       "the retention list has \(entries.count) rows, not one per stream")
expect(entries.map(\.stream) == RetentionStream.allCases.map(\.rawValue),
       "the retention list is not in stream order: \(entries.map(\.stream))")

func entry(_ stream: RetentionStream) -> TPHealthRetention? {
    entries.first { $0.stream == stream.rawValue }
}

expect(entry(.dictationText)?.rule == .kept, "dictation text is not kept")
expect(entry(.activityLines)?.rule == .kept, "activity lines, reviews and the ledger are not kept")
expect(entry(.recognisedText)?.rule == .kept, "recognised text is not kept")
expect(entry(.linkedPictures)?.rule == .kept, "a picture linked to a thread is not kept")
expect(entry(.unlinkedPictures)?.rule == .budget, "unlinked pictures are not under the one budget")
expect(entry(.unlinkedPictures)?.value == 25, "the budget row does not carry the set value")
expect(entry(.undeliveredRecordings)?.rule == .untilDelivered,
       "undelivered recordings are not kept until delivered")
expect(entry(.derivedCrops)?.rule == .days, "derived crops are not removed after days")
expect(entry(.derivedCrops)?.value == 1, "derived crops are not kept for exactly one day")

// The table is read from the setting, not hard-coded: two budgets give two rows.
expect(RetentionRules.retention(budgetGB: 3).first { $0.stream == RetentionStream.unlinkedPictures.rawValue }?
        .value == 3,
       "the retention row ignores the budget it was asked for")

// ── the bulk guard's two thresholds ───────────────────────────────────────

expect(RetentionRules.bulkBytes == 1_000_000_000, "the bulk guard's byte threshold is not 1 GB")
expect(RetentionRules.bulkDays == 7, "the bulk guard's day threshold is not 7")

// ── thinning keeps a span's first picture and the nearest to an anchor ─────

let spanA = "activity:2026-08-18T00-00-01"
let spanB = "activity:2026-08-18T00-00-11"

func picture(_ id: String, at t: Int, parent: String? = nil,
             kind: CapturedKind = .frame, source: CapturedSource = .watcher) -> RetentionPicture {
    RetentionPicture(id: id, kind: kind, source: source, tStart: t, bytes: 1_000, parentID: parent)
}

let frames = [
    picture("frame:f1", at: 1, parent: spanA),
    picture("frame:f2", at: 6, parent: spanA),
    picture("frame:f3", at: 11, parent: spanB),
    picture("frame:f4", at: 16, parent: spanB),
    picture("frame:f5", at: 21),
]
let anchors = [
    RetentionAnchor(kind: .dictation, tStart: 15),
    RetentionAnchor(kind: .shot, tStart: 12),
]
let kept = RetentionThinning.keepIDs(frames: frames, anchors: anchors)
expect(kept == ["frame:f1", "frame:f3", "frame:f4"],
       "thinning kept \(kept.sorted()), not the first of each span and the nearest to each anchor")

// A day with no anchors keeps only the first picture of each span.
let spansOnly = RetentionThinning.keepIDs(frames: frames, anchors: [])
expect(spansOnly == ["frame:f1", "frame:f3"],
       "with no anchors thinning kept \(spansOnly.sorted()), not each span's first picture")

// A frame with no parent and no anchor is never kept: there is nothing it stands for.
expect(!kept.contains("frame:f5"), "a frame that stands for nothing survived thinning")

finish("retention rules")
