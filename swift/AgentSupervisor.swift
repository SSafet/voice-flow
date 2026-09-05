import Foundation

struct AgentJobExecutionResult {
    let resultMessageID: UUID?
    let usage: AgentUsage?
}

protocol AgentJobExecuting: AnyObject {
    func execute(job: AgentJob, run: AgentRun,
                 progress: @escaping (String) -> Void) async throws -> AgentJobExecutionResult
    func cancel(runID: String) async
    /// App teardown: release long-lived runtime processes.
    func shutdown()
}

extension AgentJobExecuting {
    func shutdown() {}
}

struct AgentJobStatusUpdate {
    let jobID: String
    let runID: String?
    let state: AgentJobState
    let message: String
}

final class AgentJobRuntimeConfiguration {
    static let shared = AgentJobRuntimeConfiguration()
    private let lock = NSLock()
    private var provider: () -> AgentModelSelection = {
        AgentModelSelection(provider: "openrouter", model: "anthropic/claude-sonnet-4.5")
    }

    func configure(_ provider: @escaping () -> AgentModelSelection) {
        lock.withLock { self.provider = provider }
    }

    func model() -> AgentModelSelection { lock.withLock { provider() } }
}

enum AgentSupervisorError: LocalizedError {
    case timeout
    case missingConversation

    var errorDescription: String? {
        switch self {
        case .timeout: return "Agent job exceeded its maximum runtime."
        case .missingConversation: return "Agent job's conversation no longer exists."
        }
    }
}

/// Durable run admission stays above both runtimes. Idle agents are rows, not
/// permanently-open model calls; workers exist only for leased runs.
actor AgentSupervisor {
    private let store: AgentJobStore
    private let executor: any AgentJobExecuting
    private let workerID: String
    private var loopTask: Task<Void, Never>?
    private var running: [String: Task<Void, Never>] = [:]
    private var operatorControlledRuns: Set<String> = []
    private var shuttingDown = false
    private var reportedTerminal: [String: AgentJobState] = [:]
    var onStatus: ((AgentJobStatusUpdate) -> Void)?

    private let recoverySweepInterval: TimeInterval

    init(store: AgentJobStore, executor: any AgentJobExecuting,
         workerID: String = "voice-flow-\(UUID().uuidString)",
         recoverySweepInterval: TimeInterval = 30) {
        self.store = store
        self.executor = executor
        self.workerID = workerID
        self.recoverySweepInterval = recoverySweepInterval
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func setStatusHandler(_ handler: @escaping (AgentJobStatusUpdate) -> Void) {
        onStatus = handler
    }

    func shutdown() async {
        shuttingDown = true
        loopTask?.cancel()
        loopTask = nil
        let tasks = running
        running.removeAll()
        // App teardown is not an execution failure: suppress the tasks'
        // cancellation write, join them, then hand the leased runs back so
        // the next launch resumes them instead of recording a fake failure.
        operatorControlledRuns.formUnion(tasks.keys)
        for (runID, task) in tasks {
            task.cancel()
            await executor.cancel(runID: runID)
        }
        for task in tasks.values { await task.value }
        executor.shutdown()
        for runID in tasks.keys {
            _ = try? store.releaseInterrupted(
                runID: runID, workerID: workerID, reason: "app quit")
        }
        operatorControlledRuns.subtract(tasks.keys)
    }

    func wake() async { await admit() }

    func stopRun(jobID: String) async throws {
        let transition = try store.stopActiveRun(jobID: jobID)
        guard transition.didTransition else { return }
        await cancelAndJoin(transition.cancelledRunIDs)
        emit(AgentJobStatusUpdate(
            jobID: jobID, runID: nil, state: transition.job.state,
            message: transition.job.state == .queued
                ? "Automation stopped. Its next run remains scheduled."
                : "Automation stopped and remains ready."))
    }

    func disable(jobID: String) async throws {
        let transition = try store.disable(jobID: jobID)
        await cancelAndJoin(transition.cancelledRunIDs)
        emit(AgentJobStatusUpdate(
            jobID: jobID, runID: nil, state: .disabled,
            message: "Automation disabled."))
    }

    func enable(jobID: String) async throws {
        let transition = try store.enable(jobID: jobID)
        guard transition.didTransition else { return }
        emit(AgentJobStatusUpdate(
            jobID: jobID, runID: nil, state: transition.job.state,
            message: transition.job.state == .failed
                ? "Automation enabled. It stays failed until you retry it."
                : transition.job.state == .queued
                    ? "Automation enabled. Its next run is scheduled."
                    : "Automation enabled and ready."))
        await admit()
    }

    @discardableResult
    func runNow(jobID: String) async throws -> AgentRunNowOutcome {
        let outcome = try store.runNow(jobID: jobID)
        if case .queued(let job) = outcome {
            emit(AgentJobStatusUpdate(
                jobID: jobID, runID: nil, state: .queued,
                message: "Automation queued to run now."))
            await admit()
        }
        return outcome
    }

    private func cancelAndJoin(_ runIDs: [String]) async {
        guard !runIDs.isEmpty else { return }
        operatorControlledRuns.formUnion(runIDs)
        let tasks = runIDs.reduce(into: [String: Task<Void, Never>]()) { result, id in
            if let task = running[id] { result[id] = task; task.cancel() }
        }
        for id in runIDs { await executor.cancel(runID: id) }
        for id in runIDs { await tasks[id]?.value }
        operatorControlledRuns.subtract(runIDs)
    }

    private func runLoop() async {
        // The recovery sweep must repeat: after a crash the stale run's lease
        // can outlive the relaunch by up to the job's whole max duration, and
        // a launch-only sweep would leave it consuming a concurrency slot —
        // and blocking Edit/Run/Delete — for the entire session.
        _ = try? store.recoverExpired()
        var lastSweep = Date()
        while !Task.isCancelled {
            await admit()
            if Date().timeIntervalSince(lastSweep) >= recoverySweepInterval {
                lastSweep = Date()
                _ = try? store.recoverExpired()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func admit() async {
        guard !shuttingDown else { return }
        while running.count < AgentJobStore.globalConcurrency {
            guard let run = try? store.claimNext(workerID: workerID),
                  let job = try? store.job(id: run.jobID) else { break }
            emit(AgentJobStatusUpdate(
                jobID: job.id, runID: run.id, state: .running,
                message: "\(job.runtime.label) agent started."))
            running[run.id] = Task { [weak self] in
                await self?.execute(job: job, run: run)
            }
        }
        reportNewTerminalStates()
    }

    private func execute(job: AgentJob, run: AgentRun) async {
        let heartbeat = Task { [store, workerID] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                _ = try? store.heartbeat(
                    runID: run.id, workerID: workerID,
                    leaseSeconds: max(30, job.maxDurationSeconds + 10))
            }
        }
        defer { heartbeat.cancel() }
        do {
            let result = try await withThrowingTaskGroup(
                of: AgentJobExecutionResult.self
            ) { group in
                group.addTask { [executor] in
                    try await executor.execute(job: job, run: run) { [weak self] detail in
                        Task { await self?.emitProgress(
                            jobID: job.id, runID: run.id, detail: detail) }
                    }
                }
                group.addTask {
                    try await Task.sleep(
                        nanoseconds: UInt64(max(1, job.maxDurationSeconds) * 1_000_000_000))
                    throw AgentSupervisorError.timeout
                }
                do {
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                } catch {
                    // A runtime waiting on a process/socket continuation may
                    // not observe Task cancellation by itself. Cancel the
                    // concrete executor before the task-group scope joins it,
                    // otherwise the maximum-runtime guard can deadlock.
                    if error is AgentSupervisorError {
                        await executor.cancel(runID: run.id)
                    }
                    group.cancelAll()
                    throw error
                }
            }
            let cost = result.usage?.costUSD.map {
                NSDecimalNumber(decimal: $0).doubleValue
            } ?? 0
            let finish = try store.complete(
                runID: run.id, workerID: workerID,
                resultMessageID: result.resultMessageID, costUSD: cost)
            if finish == .applied {
                emit(AgentJobStatusUpdate(
                    jobID: job.id, runID: run.id, state: .completed,
                    message: "Agent job completed."))
            }
        } catch is CancellationError {
            if !operatorControlledRuns.contains(run.id) {
                _ = try? store.fail(
                    runID: run.id, workerID: workerID,
                    error: "cancelled", retryable: false)
            }
        } catch {
            if operatorControlledRuns.contains(run.id) {
                running.removeValue(forKey: run.id)
                await admit()
                return
            }
            await executor.cancel(runID: run.id)
            let retryable = (error as? AgentRuntimeFailure)?.retryable
                ?? !(error is AgentSupervisorError)
            let jitterSeed = run.id.utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
            let retryDelay = 3.0 + Double(jitterSeed % 4_000) / 1_000
            let finish = try? store.fail(
                runID: run.id, workerID: workerID,
                error: AgentSecretPolicy.redacted(error.localizedDescription),
                retryable: retryable, retryDelay: retryDelay)
            if finish == .superseded {
                running.removeValue(forKey: run.id)
                await admit()
                return
            }
            let durableState = (try? store.job(id: job.id)?.state) ?? .failed
            if durableState == .blocked || durableState == .failed {
                reportedTerminal[job.id] = durableState
            }
            emit(AgentJobStatusUpdate(
                jobID: job.id, runID: run.id, state: durableState,
                message: durableState == .queued
                    ? "\(error.localizedDescription) Retrying with backoff."
                    : error.localizedDescription))
        }
        running.removeValue(forKey: run.id)
        await admit()
    }

    private func reportNewTerminalStates() {
        guard let jobs = try? store.jobs(limit: 500) else { return }
        for job in jobs {
            guard job.state == .blocked || job.state == .failed else {
                reportedTerminal.removeValue(forKey: job.id)
                continue
            }
            guard reportedTerminal[job.id] != job.state else { continue }
            reportedTerminal[job.id] = job.state
            let message = job.state == .blocked
                ? "Agent job blocked by its daily budget or attempt limit."
                : "Agent job exhausted its retry policy."
            emit(AgentJobStatusUpdate(
                jobID: job.id, runID: nil, state: job.state, message: message))
        }
    }

    private func emit(_ update: AgentJobStatusUpdate) {
        onStatus?(update)
    }

    private func emitProgress(jobID: String, runID: String, detail: String) {
        guard !operatorControlledRuns.contains(runID),
              (try? store.run(id: runID)?.state) == .running else { return }
        emit(AgentJobStatusUpdate(
            jobID: jobID, runID: runID, state: .running, message: detail))
    }
}
