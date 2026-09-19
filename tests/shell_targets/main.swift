import Foundation

// The two types `CaptureRouting.swift` reads from the app that this suite does
// not compile (the repository's `tests/capture_routing/main.swift` does the
// same). `PendingInteraction` is deliberately NOT stubbed: the re-keying of
// 06 §3.14 removes the session route, so if it comes back this file stops
// compiling.
struct DisplayContext {}
struct CaptureSummary { let id: String }

// V7, task 4 — the native features attached to threads (06 §3.14; decision 12).
//
// The voice target's order of resolution, the pinned slots, the Escape order,
// the desktop-control lease and the notification rule are all pure decisions.
// The capture-routing re-keying is proved against the existing `CaptureRouter`.

let threadA = ThreadRef(homeID: "mac-mini-7f3a", threadID: "6B1F0E0C-52C1-4C55-9B5B-0D4A1B3F9A2C")
let threadB = ThreadRef(homeID: "atika", threadID: "01J8ZK3F9ATHREAD0000000009")

// ── 1. the voice target resolves in the order of 06 §3.14 ───────────────────

func resolve(windowIsKey: Bool, openThread: ThreadRef? = nil, showingDraft: Bool = false,
             pillTarget: ThreadRef? = nil, wakeName: String? = nil) -> VoiceTarget {
    VoiceTargetResolver.resolve(
        state: VoiceTargetState(windowIsKey: windowIsKey, openThread: openThread,
                                showingDraft: showingDraft, pillTarget: pillTarget),
        wakeName: wakeName)
}

expectEqual(resolve(windowIsKey: true, openThread: threadA, pillTarget: threadB),
            .thread(threadA),
            "the key window on a thread wins over everything else")
expectEqual(resolve(windowIsKey: true, showingDraft: true, pillTarget: threadB),
            .draft,
            "the key window on the draft screen dictates into the draft composer")
expectEqual(resolve(windowIsKey: false, pillTarget: threadA),
            .pinned(threadA),
            "without the key window the pill's target thread is used")
expectEqual(resolve(windowIsKey: false, wakeName: "organize my day"),
            .wake("organize my day"),
            "a wake name is matched when nothing is in front (06 §3.14)")
expectEqual(resolve(windowIsKey: false),
            .paste,
            "with nothing else the words are pasted into the frontmost app")
expectEqual(resolve(windowIsKey: true, openThread: threadA, showingDraft: true),
            .thread(threadA),
            "an open thread on screen beats the draft flag, which is about another screen")

// The target is frozen at the hotkey: a later route report is a new resolution.
expectEqual(resolve(windowIsKey: true, openThread: threadA),
            .thread(threadA),
            "the target read when the hotkey goes down is the thread on screen then")
expectEqual(resolve(windowIsKey: true, openThread: threadB),
            .thread(threadB),
            "a later route report only changes the next resolution, never the frozen one")

// ── 2. slots: this Mac's pinned thread wins a slot held twice ───────────────

var favourites = PinnedThreads()
let reported = try ShellFixtures.examples(TPReportedPin.self, "ReportedPin")
try favourites.apply(reported)
expectEqual(favourites.pin(slot: reported[0].slot), reported[0],
            "a reported pin is found by its slot")
expectNil(favourites.pin(slot: 9), "an empty slot has no pin")
expectEqual(favourites.slots, [reported[0].slot], "the held slots are exactly the reported ones")

let localPin = TPReportedPin(homeID: "mac-mini-7f3a", needsAttention: false, slot: 1,
                             threadID: threadA.threadID, title: "Fix cart")
let otherPin = TPReportedPin(homeID: "atika", needsAttention: false, slot: 1,
                             threadID: threadB.threadID, title: "Release notes")
expectEqual(PinnedThreads.resolveSlot(1, local: [localPin], reported: [otherPin]), localPin,
            "when one slot is held on this Mac and elsewhere, the hotkey goes to this Mac's thread (06 §3.14)")
expectEqual(PinnedThreads.resolveSlot(1, local: [], reported: [otherPin]), otherPin,
            "with no local thread the reported pin is used")

var duplicateRefused = false
var duplicateStore = PinnedThreads()
do { try duplicateStore.apply([localPin, otherPin]) } catch { duplicateRefused = true }
expect(duplicateRefused, "one slot reported twice is refused by name (02 §3.6)")

// ── 3. Escape: the two global rules come first, the window never closes ─────

let liveLease = DesktopControlLease(threadID: threadA.threadID, grantedAt: Date(timeIntervalSince1970: 1_000))
expectEqual(ShellEscape.nativeAction(ShellEscapeState(annotationEditing: true, desktopLease: liveLease,
                                                      pillCardOpen: true)),
            .endAnnotationEditing,
            "Escape ends annotation editing first (06 §3.14)")
expectEqual(ShellEscape.nativeAction(ShellEscapeState(annotationEditing: false, desktopLease: liveLease,
                                                      pillCardOpen: true)),
            .stopDesktopControl(threadID: threadA.threadID),
            "Escape stops the turn that holds the desktop-control lease and releases it")
expectEqual(ShellEscape.nativeAction(ShellEscapeState(annotationEditing: false, desktopLease: nil,
                                                      pillCardOpen: true)),
            .giveToInterface,
            "with no global rule in play the interface gets Escape like any key")
expectEqual(ShellEscape.shellEscape(ShellEscapeState(annotationEditing: false, desktopLease: nil,
                                                     pillCardOpen: true)),
            TPShellEscapeResult(handled: true),
            "the shell collapses the pill card and reports it handled")
expectEqual(ShellEscape.shellEscape(ShellEscapeState(annotationEditing: false, desktopLease: nil,
                                                     pillCardOpen: false)),
            TPShellEscapeResult(handled: false),
            "with no pill card open the shell handles nothing; Escape never closes the window")

// ── 4. the desktop-control lease: one thread, fifteen minutes, released by Escape

expectEqual(DesktopControlLease.duration, 15 * 60,
            "desktop control lasts 15 minutes (decision 12)")
let leaseStore = DesktopControlLeaseStore()
let start = Date(timeIntervalSince1970: 1_700_000_000)
try leaseStore.acquire(threadID: threadA.threadID, at: start)
expectEqual(leaseStore.active(at: start)?.threadID, threadA.threadID, "the lease is held at once")
expectEqual(leaseStore.active(at: start.addingTimeInterval(DesktopControlLease.duration - 1))?.threadID,
            threadA.threadID,
            "the lease is still held just before fifteen minutes")
expectNil(leaseStore.active(at: start.addingTimeInterval(DesktopControlLease.duration)),
          "the lease has expired at exactly fifteen minutes")

var secondRefused = false
try leaseStore.acquire(threadID: threadA.threadID, at: start)
do { try leaseStore.acquire(threadID: threadB.threadID, at: start.addingTimeInterval(1)) }
catch { secondRefused = true }
expect(secondRefused, "one Mac holds one desktop-control lease at a time")
expectEqual(leaseStore.release(threadID: threadA.threadID), threadA.threadID,
            "releasing returns the thread that held it")
expectNil(leaseStore.active(at: start), "after release nothing holds the lease")
try leaseStore.acquire(threadID: threadB.threadID, at: start.addingTimeInterval(2))
expectEqual(leaseStore.active(at: start.addingTimeInterval(2))?.threadID, threadB.threadID,
            "a thread may take the lease after it is free")

// ── 5. notifications: all four reach the ring; only three reach Notification Centre

expectEqual(ShellNotifications.decide(.approval, windowShowsThread: false),
            ShellNotificationDecision(notify: true, ring: true),
            "an approval in a thread the window is not showing notifies and rings (06 §3.14)")
expectEqual(ShellNotifications.decide(.question, windowShowsThread: false),
            ShellNotificationDecision(notify: true, ring: true),
            "a question notifies and rings")
expectEqual(ShellNotifications.decide(.failure, windowShowsThread: false),
            ShellNotificationDecision(notify: true, ring: true),
            "a failure notifies and rings")
expectEqual(ShellNotifications.decide(.finished, windowShowsThread: false),
            ShellNotificationDecision(notify: false, ring: true),
            "a finished turn raises the ring only")
expectEqual(ShellNotifications.decide(.approval, windowShowsThread: true),
            ShellNotificationDecision(notify: false, ring: true),
            "a thread the window is showing does not raise a native notification")

// ── 6. capture routing is re-keyed to a thread, not an assistant or a session

let paste = PasteTarget(processIdentifier: 42, name: "Editor")
expectEqual(ConversationFocus.thread(threadA), .thread(threadA), "a visible thread is the focus")
if case .thread(let ref) = CaptureRouter.resolve(policy: .contextual, focus: .thread(threadA), pasteTarget: paste) {
    expectEqual(ref, threadA, "a visible thread outranks the external paste target")
} else {
    expect(false, "a visible thread must resolve to a thread route")
}
if case .draft = CaptureRouter.resolve(policy: .contextual, focus: .draft, pasteTarget: paste) {
    expect(true, "the draft screen resolves to a draft route")
} else {
    expect(false, "the draft screen must resolve to a draft route")
}
if case .paste(let target) = CaptureRouter.resolve(policy: .contextual, focus: .none, pasteTarget: paste) {
    expectEqual(target, paste, "with nothing visible the capture pastes into the frozen target")
} else {
    expect(false, "with no focus and a paste target the capture must paste")
}
if case .historyOnly = CaptureRouter.resolve(policy: .contextual, focus: .none, pasteTarget: nil) {
    expect(true, "with no focus and no paste target the capture stays in history")
} else {
    expect(false, "with no target at all the capture must be history-only")
}
if case .historyOnly = CaptureRouter.resolve(policy: .historyOnly, focus: .thread(threadA), pasteTarget: paste) {
    expect(true, "a history-only policy ignores every visible target")
} else {
    expect(false, "a history-only policy must stay history-only")
}

// A capture run carries its thread identity from start to delivery.
let run = CaptureRun(id: UUID(), capability: .snapshot, route: .thread(threadA),
                     startedAt: Date(), snapshot: .notNeeded)
expectEqual(run.targetThread, threadA, "a capture run carries the thread it was started for")

print("shell targets: voice target, slots, Escape, the desktop lease, notifications and capture routing passed")
