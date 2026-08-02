import Foundation

struct AgentJobExecutionResult {
    let resultMessageID: UUID?
    let usage: AgentUsage?
}

protocol AgentJobExecuting: AnyObject {
    func execute(job: AgentJob, run: AgentRun,
                 progress: @escaping (String) -> Void) async throws -> AgentJobExecutionResult
    func cancel(runID: String) async
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
    private var reportedTerminal: [String: AgentJobState] = [:]
    var onStatus: ((AgentJobStatusUpdate) -> Void)?

    init(store: AgentJobStore, executor: any AgentJobExecuting,
         workerID: String = "voice-flow-\(UUID().uuidString)") {
        self.store = store
        self.executor = executor
        self.workerID = workerID
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    func setStatusHandler(_ handler: @escaping (AgentJobStatusUpdate) -> Void) {
        onStatus = handler
    }

    func stop() async {
        loopTask?.cancel()
        loopTask = nil
        let tasks = running
        running.removeAll()
        for (runID, task) in tasks {
            task.cancel()
            await executor.cancel(runID: runID)
        }
    }

    func wake() async { await admit() }

    func cancel(jobID: String) async {
        // Resolve the live executor handles before transitioning their run
        // rows out of `running`; otherwise activeRuns() can no longer find
        // the very processes cancellation must join.
        let active = ((try? store.activeRuns()) ?? []).filter { $0.jobID == jobID }
        try? store.cancel(jobID: jobID)
        for run in active {
            let task = running[run.id]
            task?.cancel()
            await executor.cancel(runID: run.id)
            await task?.value
        }
        emit(AgentJobStatusUpdate(
            jobID: jobID, runID: nil, state: .cancelled,
            message: "Agent job cancelled."))
    }

    private func runLoop() async {
        _ = try? store.recoverExpired()
        while !Task.isCancelled {
            await admit()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func admit() async {
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
                        Task { await self?.emit(AgentJobStatusUpdate(
                            jobID: job.id, runID: run.id, state: .running,
                            message: detail)) }
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
            try store.complete(
                runID: run.id, workerID: workerID,
                resultMessageID: result.resultMessageID, costUSD: cost)
            emit(AgentJobStatusUpdate(
                jobID: job.id, runID: run.id, state: .completed,
                message: "Agent job completed."))
        } catch is CancellationError {
            try? store.fail(
                runID: run.id, workerID: workerID,
                error: "cancelled", retryable: false)
        } catch {
            await executor.cancel(runID: run.id)
            let retryable = (error as? AgentRuntimeFailure)?.retryable
                ?? !(error is AgentSupervisorError)
            let jitterSeed = run.id.utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
            let retryDelay = 3.0 + Double(jitterSeed % 4_000) / 1_000
            try? store.fail(
                runID: run.id, workerID: workerID,
                error: AgentSecretPolicy.redacted(error.localizedDescription),
                retryable: retryable, retryDelay: retryDelay)
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
}
