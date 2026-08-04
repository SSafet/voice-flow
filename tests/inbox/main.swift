import Foundation

func vflog(_: String) {}

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private final class WaitBox {
    private let lock = NSLock()
    private var stored: (messages: [InboxMessage], superseded: Bool, terminated: Bool)?

    func put(_ value: (messages: [InboxMessage], superseded: Bool, terminated: Bool)) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> (messages: [InboxMessage], superseded: Bool, terminated: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private func makeInbox(_ name: String) -> MessageInbox {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("voice-flow-inbox-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return MessageInbox(storageURL: root.appendingPathComponent("\(name).json"))
}

private func waitUntil(timeout: TimeInterval = 1, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return predicate()
}

private func startWait(
    _ inbox: MessageInbox,
    session: String?,
    timeout: TimeInterval = 2
) -> (box: WaitBox, done: DispatchSemaphore) {
    let box = WaitBox()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        box.put(inbox.wait(timeout: timeout, session: session))
        done.signal()
    }
    return (box, done)
}

private func texts(_ messages: [InboxMessage]) -> [String] {
    messages.map(\.text)
}

// Directional visibility: nil consumers cannot steal A/B, while concrete
// consumers can still claim the legacy unscoped queue.
do {
    let inbox = makeInbox("directional")
    inbox.add(text: "for A", attachments: [], session: "A")
    inbox.add(text: "for B", attachments: [], session: "B")
    inbox.add(text: "unscoped", attachments: [], session: nil)

    expect(texts(inbox.drain(session: nil)) == ["unscoped"],
           "an unscoped drain must not steal targeted messages")
    expect(texts(inbox.drain(session: "A")) == ["for A"],
           "session A must receive only its targeted residue")
    expect(texts(inbox.drain(session: "B")) == ["for B"],
           "session B must retain its targeted message")
}

// A targeted A message wakes A only; B remains parked until explicitly ended.
do {
    let inbox = makeInbox("ab-waiters")
    let a = startWait(inbox, session: "A")
    let b = startWait(inbox, session: "B")
    expect(waitUntil { inbox.hasWaiter(exactSession: "A") && inbox.hasWaiter(exactSession: "B") },
           "A and B waiters should both park")

    inbox.add(text: "wake A", attachments: [], session: "A")
    expect(a.done.wait(timeout: .now() + 0.5) == .success,
           "targeted A message should wake A")
    expect(texts(a.box.get()?.messages ?? []) == ["wake A"],
           "A waiter should drain the A message")
    expect(b.done.wait(timeout: .now() + 0.1) == .timedOut,
           "targeted A message must not wake B")
    expect(inbox.hasWaiter(exactSession: "B"),
           "B waiter must remain registered after A delivery")
    expect(inbox.terminateWait(exactSession: "B") == 1,
           "exact termination should release only B")
    expect(b.done.wait(timeout: .now() + 0.5) == .success,
           "terminated B waiter should return promptly")
    expect(b.box.get()?.messages.isEmpty == true,
           "terminated B waiter must not receive A")
    expect(b.box.get()?.terminated == true,
           "explicit B termination should be distinguishable from timeout")
}

// A nil waiter is not a wildcard consumer and cannot intercept targeted work.
do {
    let inbox = makeInbox("nil-waiter")
    let unscoped = startWait(inbox, session: nil, timeout: 0.25)
    expect(waitUntil { inbox.hasWaiter(for: nil) }, "nil waiter should park")
    inbox.add(text: "private A", attachments: [], session: "A")
    expect(unscoped.done.wait(timeout: .now() + 0.1) == .timedOut,
           "nil waiter must not wake for a targeted message")
    expect(unscoped.done.wait(timeout: .now() + 0.5) == .success,
           "nil waiter should finish on its own timeout")
    expect(unscoped.box.get()?.messages.isEmpty == true,
           "nil waiter must not drain the targeted message after timeout")
    expect(unscoped.box.get()?.terminated == false,
           "ordinary timeout must not be reported as termination")
    expect(texts(inbox.drain(session: "A")) == ["private A"],
           "targeted A message must remain queued")
}

// Unscoped messages remain deliverable to a concrete session.
do {
    let inbox = makeInbox("unscoped-delivery")
    let a = startWait(inbox, session: "A")
    expect(waitUntil { inbox.hasWaiter(exactSession: "A") }, "A waiter should park")
    inbox.add(text: "anyone", attachments: [], session: nil)
    expect(a.done.wait(timeout: .now() + 0.5) == .success,
           "an unscoped message should wake a concrete waiter")
    expect(texts(a.box.get()?.messages ?? []) == ["anyone"],
           "concrete waiter should drain the unscoped message")
}

// Exact queued removal preserves both other sessions and legacy unscoped work.
do {
    let inbox = makeInbox("remove-exact")
    inbox.add(text: "A1", attachments: [], session: "A")
    inbox.add(text: "B1", attachments: [], session: "B")
    inbox.add(text: "anyone", attachments: [], session: nil)
    inbox.add(text: "A2", attachments: [], session: "A")

    expect(inbox.removeQueued(exactSession: "A") == 2,
           "exact removal should report both A messages")
    expect(inbox.removeQueued(exactSession: "A") == 0,
           "repeated exact removal should be idempotent")
    expect(texts(inbox.drain(session: nil)) == ["anyone"],
           "exact A removal must preserve unscoped messages")
    expect(texts(inbox.drain(session: "B")) == ["B1"],
           "exact A removal must preserve B messages")
}

// Termination returns promptly, unregisters the exact waiter, and prevents it
// from consuming a message queued immediately after deletion.
do {
    let inbox = makeInbox("termination")
    let a = startWait(inbox, session: "A")
    let b = startWait(inbox, session: "B")
    expect(waitUntil { inbox.hasWaiter(exactSession: "A") && inbox.hasWaiter(exactSession: "B") },
           "termination fixtures should park")

    expect(inbox.terminateWait(exactSession: "A") == 1,
           "termination should find exactly one A waiter")
    inbox.add(text: "after delete", attachments: [], session: "A")
    expect(a.done.wait(timeout: .now() + 0.5) == .success,
           "A termination should wake the waiter immediately")
    expect(a.box.get()?.messages.isEmpty == true,
           "terminated A waiter must not consume a racing message")
    expect(a.box.get()?.terminated == true,
           "A waiter should report exact-session termination")
    expect(!inbox.hasWaiter(exactSession: "A"),
           "terminated A waiter should be unregistered")
    expect(inbox.hasWaiter(exactSession: "B"),
           "A termination must not affect B")
    expect(texts(inbox.drain(session: "A")) == ["after delete"],
           "message queued after A deletion should remain queued")

    inbox.cancelWait(for: "B")
    expect(b.done.wait(timeout: .now() + 0.5) == .success,
           "compatibility cancelWait should perform real termination")

    expect(inbox.terminateWait(exactSession: "C") == 0,
           "termination without a current waiter should report zero")
    let late = startWait(inbox, session: "C")
    expect(late.done.wait(timeout: .now() + 0.5) == .success,
           "a wait racing just after deletion should not park")
    expect(late.box.get()?.terminated == true,
           "a late wait should observe the exact-session tombstone")
    inbox.clearUserClosed("C")
    let reengaged = startWait(inbox, session: "C")
    expect(waitUntil { inbox.hasWaiter(exactSession: "C") },
           "explicit re-engagement should allow a new C waiter")
    inbox.terminateWait(exactSession: "C")
    expect(reengaged.done.wait(timeout: .now() + 0.5) == .success,
           "re-engaged C waiter should remain terminable")
}

// Existing exact-session supersession remains intact.
do {
    let inbox = makeInbox("supersession")
    let old = startWait(inbox, session: "A")
    expect(waitUntil { inbox.hasWaiter(exactSession: "A") }, "old A waiter should park")
    let replacement = startWait(inbox, session: "A")
    expect(old.done.wait(timeout: .now() + 0.5) == .success,
           "replacement should release old A waiter")
    expect(old.box.get()?.superseded == true,
           "released old waiter should be marked superseded")
    expect(old.box.get()?.terminated == false,
           "supersession must remain distinct from termination")
    expect(waitUntil { inbox.hasWaiter(exactSession: "A") },
           "replacement A waiter should remain parked")
    inbox.add(text: "replacement only", attachments: [], session: "A")
    expect(replacement.done.wait(timeout: .now() + 0.5) == .success,
           "replacement waiter should receive the next A message")
    expect(texts(replacement.box.get()?.messages ?? []) == ["replacement only"],
           "old waiter must not steal replacement delivery")
}

// Complete → Reopen → reply: reopening (clearUserClosed) must lift the
// closed-session tombstone, or the agent's next wait_for_message is told the
// session terminated and the user's queued reply strands forever.
do {
    let inbox = makeInbox("reopen")
    inbox.terminateWait(exactSession: "S")
    let closed = inbox.wait(timeout: 0.1, session: "S")
    expect(closed.terminated, "a completed session must terminate its waiters")

    inbox.clearUserClosed("S")
    inbox.add(text: "reply after reopen", attachments: [], session: "S")
    let reopened = inbox.wait(timeout: 0.5, session: "S")
    expect(!reopened.terminated,
           "reopen did not lift the closed-session tombstone — the listener is still told terminated")
    expect(texts(reopened.messages) == ["reply after reopen"],
           "the queued reply was not delivered after reopen")
}

if failures > 0 {
    fputs("\(failures) inbox test(s) failed\n", stderr)
    exit(1)
}

print("inbox tests passed")
