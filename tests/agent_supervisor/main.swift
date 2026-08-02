import Foundation

func vflog(_ message: String) {}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

final class FakeExecutor: AgentJobExecuting {
    private let lock = NSLock()
    private var active = 0
    private(set) var peak = 0
    private(set) var seen: [String: String] = [:]

    func execute(job: AgentJob, run: AgentRun,
                 progress: @escaping (String) -> Void) async throws -> AgentJobExecutionResult {
        lock.withLock {
            active += 1
            peak = max(peak, active)
            seen[job.id] = job.prompt
        }
        defer { lock.withLock { active -= 1 } }
        progress("running \(job.id)")
        try await Task.sleep(nanoseconds: 120_000_000)
        return AgentJobExecutionResult(resultMessageID: UUID(), usage: nil)
    }

    func cancel(runID: String) async {}
}

let now = Date()
let store = try AgentJobStore(url: VoiceFlowPaths.shared.file("supervisor-test.sqlite"))
for index in 1...3 {
    try store.put(AgentJob(
        id: "job-\(index)", assistantSlug: "flora",
        conversationID: "conversation-\(index)", runtime: index == 1 ? .codex : .opencode,
        trigger: .manual, prompt: "nonce-\(index)", nextRunAt: now,
        concurrencyKey: "key-\(index)", maxDurationSeconds: 5,
        createdAt: now.addingTimeInterval(Double(index) / 100),
        updatedAt: now.addingTimeInterval(Double(index) / 100)))
}
let executor = FakeExecutor()
let supervisor = AgentSupervisor(store: store, executor: executor, workerID: "test-worker")
var states: [AgentJobState] = []
await supervisor.setStatusHandler { update in states.append(update.state) }
await supervisor.start()
let deadline = Date().addingTimeInterval(4)
while Date() < deadline {
    let jobs = try store.jobs()
    if jobs.allSatisfy({ $0.state == .completed }) { break }
    try await Task.sleep(nanoseconds: 40_000_000)
}
await supervisor.stop()
let jobs = try store.jobs()
expect(jobs.allSatisfy { $0.state == .completed }, "supervisor did not drain three jobs")
expect(executor.peak == 3, "three isolated workers were not admitted concurrently")
expect(executor.seen == ["job-1": "nonce-1", "job-2": "nonce-2", "job-3": "nonce-3"],
       "job prompt text leaked or crossed workers")
expect(states.filter { $0 == .completed }.count == 3, "completion status was not surfaced")
let activeRuns = try store.activeRuns()
expect(activeRuns.isEmpty, "supervisor did not reach idle")

final class CancellationExecutor: AgentJobExecuting {
    private let lock = NSLock()
    private(set) var finished = false
    func execute(job: AgentJob, run: AgentRun,
                 progress: @escaping (String) -> Void) async throws -> AgentJobExecutionResult {
        defer { lock.withLock { finished = true } }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return AgentJobExecutionResult(resultMessageID: nil, usage: nil)
    }
    func cancel(runID: String) async {}
}
let cancelStore = try AgentJobStore(url: VoiceFlowPaths.shared.file("supervisor-cancel.sqlite"))
let cancelJob = AgentJob(
    id: "cancel-job", assistantSlug: "flora", conversationID: "cancel-conversation",
    runtime: .opencode, trigger: .manual, prompt: "cancel me", nextRunAt: Date(),
    maxDurationSeconds: 60)
try cancelStore.put(cancelJob)
let cancellationExecutor = CancellationExecutor()
let cancelSupervisor = AgentSupervisor(
    store: cancelStore, executor: cancellationExecutor, workerID: "cancel-worker")
await cancelSupervisor.start()
let cancelDeadline = Date().addingTimeInterval(2)
while Date() < cancelDeadline {
    if try cancelStore.job(id: cancelJob.id)?.state == .running { break }
    try await Task.sleep(nanoseconds: 20_000_000)
}
await cancelSupervisor.cancel(jobID: cancelJob.id)
expect(cancellationExecutor.finished,
       "cancel returned before the active executor had fully unwound")
let cancelledState = try cancelStore.job(id: cancelJob.id)?.state
expect(cancelledState == .cancelled,
       "joined cancellation did not preserve the durable cancelled state")
await cancelSupervisor.stop()

final class TimeoutExecutor: AgentJobExecuting {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AgentJobExecutionResult, Error>?
    private var cancellationObserved = false
    var cancelled: Bool { lock.withLock { cancellationObserved } }

    func execute(job: AgentJob, run: AgentRun,
                 progress: @escaping (String) -> Void) async throws -> AgentJobExecutionResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func cancel(runID: String) async {
        let waiting = lock.withLock { () -> CheckedContinuation<AgentJobExecutionResult, Error>? in
            cancellationObserved = true
            let waiting = continuation
            continuation = nil
            return waiting
        }
        waiting?.resume(throwing: CancellationError())
    }
}
let timeoutStore = try AgentJobStore(url: VoiceFlowPaths.shared.file("supervisor-timeout.sqlite"))
let timeoutJob = AgentJob(
    id: "timeout-job", assistantSlug: "flora", conversationID: "timeout-conversation",
    runtime: .opencode, trigger: .manual, prompt: "time out", nextRunAt: Date(),
    maxDurationSeconds: 1, maxAttempts: 1)
try timeoutStore.put(timeoutJob)
let timeoutExecutor = TimeoutExecutor()
let timeoutSupervisor = AgentSupervisor(
    store: timeoutStore, executor: timeoutExecutor, workerID: "timeout-worker")
await timeoutSupervisor.start()
let timeoutDeadline = Date().addingTimeInterval(4)
while Date() < timeoutDeadline {
    if try timeoutStore.job(id: timeoutJob.id)?.state == .failed { break }
    try await Task.sleep(nanoseconds: 20_000_000)
}
expect(timeoutExecutor.cancelled,
       "maximum runtime did not cancel an executor that ignored Task cancellation")
let timeoutState = try timeoutStore.job(id: timeoutJob.id)?.state
let timeoutRuns = try timeoutStore.activeRuns()
expect(timeoutState == .failed,
       "maximum runtime did not leave a terminal failed job")
expect(timeoutRuns.isEmpty,
       "timed-out run remained leased")
await timeoutSupervisor.stop()
print("agent supervisor tests passed")
