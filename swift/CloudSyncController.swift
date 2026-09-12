import Cocoa
import SwiftUI

@MainActor
final class CloudSyncController: ObservableObject {
    static let shared = CloudSyncController()
    @Published var originDraft = "https://api.atika.ai"
    @Published var emailDraft = ""
    @Published var codeDraft = ""
    @Published private(set) var selection: CloudAccountSelection
    @Published private(set) var status = "Local only"
    @Published private(set) var busy = false
    @Published private(set) var challenge: CloudLoginChallenge.Challenge?
    @Published private(set) var records: [CloudLocalRecord] = []
    @Published private(set) var conflicts: [CloudConflict] = []
    @Published private(set) var requiresBaselineReview = false
    @Published private(set) var reviewCount = 0
    var onInboxChanged: (() -> Void)?
    var onTransportChanged: ((Bool) -> Void)?
    var onContinueConversation: ((String) -> Void)?
    private let bridge = CloudSyncBridge.shared
    private let vault: CloudCredentialVault
    private var client: CloudHTTPClient?
    private var clientPartition: String?
    private var syncTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private var timer: Timer?
    private var installed = false
    private var lastFailure: String?

    private init() {
        let saved = CloudSyncBridge.shared.currentSelection()
        selection = saved
        originDraft = saved.origin; emailDraft = saved.email
        // An isolated QA config root must never touch production credentials.
        let namespace = VoiceFlowPaths.shared.isIsolated
            ? "com.voiceflow.cloud-sync.qa.\(VoiceFlowPaths.shared.configRoot.lastPathComponent)"
            : "com.voiceflow.cloud-sync"
        vault = CloudKeychainVault(namespace: namespace)
    }
    func start() {
        guard !installed else { return }
        installed = true
        bridge.installHooks()
        bridge.onChange = { [weak self] in
            Task { @MainActor in self?.refreshState(); self?.sync() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        refreshState()
        onTransportChanged?(selection.transport == "cloud")
        sync()
    }
    func setTransport(_ value: String) {
        guard ["local", "cloud"].contains(value) else { return }
        syncTask?.cancel(); syncTask = nil; activeRunID = nil; busy = false
        var saved = selection; saved.transport = value
        do { try bridge.saveSelection(saved); selection = saved; lastFailure = nil; refreshState() }
        catch { lastFailure = error.localizedDescription; refreshState() }
        onTransportChanged?(value == "cloud")
        if value == "cloud" { sync() }
    }
    func setExports(_ exports: CloudExportSelection) {
        syncTask?.cancel(); syncTask = nil; activeRunID = nil; busy = false
        var saved = selection; saved.exports = exports
        do { try bridge.saveSelection(saved); selection = saved; lastFailure = nil; refreshState(); sync() }
        catch { lastFailure = error.localizedDescription; refreshState() }
    }
    func beginLogin() {
        guard !busy else { return }
        busy = true; lastFailure = nil
        Task {
            defer { busy = false; refreshState() }
            do {
                let transport = try CloudHTTPClient(origin: originDraft, vault: vault)
                let next = try await transport.start(email: emailDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                client = transport; clientPartition = nil; challenge = next; codeDraft = ""
            } catch { lastFailure = error.localizedDescription }
        }
    }
    func completeLogin() {
        guard !busy, let challenge, let client else { return }
        busy = true; lastFailure = nil
        Task {
            defer { busy = false; refreshState() }
            do {
                let credentials = try await client.complete(challenge: challenge, code: codeDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                    label: Host.current().localizedName ?? "Mac")
                syncTask?.cancel(); syncTask = nil; activeRunID = nil
                let priorExports = try bridge.store?.state(credentials.partition).exports
                let saved = CloudAccountSelection(origin: credentials.origin, userID: credentials.userID,
                    email: credentials.email, deviceID: credentials.deviceID, transport: "cloud", signedIn: true,
                    exports: priorExports ?? selection.included)
                try bridge.saveSelection(saved)
                selection = saved; clientPartition = credentials.partition
                self.challenge = nil; codeDraft = ""
                onTransportChanged?(true)
                busy = false
                sync()
            } catch { lastFailure = error.localizedDescription }
        }
    }
    func cancelLogin() {
        guard !busy, challenge != nil else { return }
        challenge = nil; codeDraft = ""; client = nil; clientPartition = nil
        lastFailure = nil; refreshState()
    }
    func signOut() {
        guard !busy else { return }
        syncTask?.cancel(); syncTask = nil; activeRunID = nil; busy = true
        Task {
            defer { busy = false; refreshState() }
            do {
                var saved = selection; saved.signedIn = false
                try bridge.saveSelection(saved); selection = saved
                if let client { try await client.logout() }
                else if let partition = saved.partition, let credential = try vault.load(partition: partition) {
                    let transport = try CloudHTTPClient(origin: credential.origin, credentials: credential, vault: vault)
                    try await transport.logout()
                }
                client = nil; clientPartition = nil; lastFailure = nil
            } catch { lastFailure = error.localizedDescription }
        }
    }
    func sync() {
        selection = bridge.currentSelection()
        guard selection.transport == "cloud", selection.signedIn, syncTask == nil, !busy,
              let partition = selection.partition else { return }
        let runID = UUID(); activeRunID = runID
        syncTask = Task {
            defer {
                if activeRunID == runID { syncTask = nil; activeRunID = nil; busy = false; refreshState() }
            }
            busy = true; lastFailure = nil; status = "Syncing…"
            do {
                guard let store = bridge.store else { throw CloudSyncError.storage("unavailable") }
                try bridge.bootstrapIfNeeded()
                if try store.state(partition).requiresBaselineReview { throw CloudSyncError.historyChanged }
                if client == nil || clientPartition != partition {
                    guard let credentials = try vault.load(partition: partition) else { throw CloudSyncError.signInRequired }
                    client = try CloudHTTPClient(origin: credentials.origin, credentials: credentials, vault: vault)
                    clientPartition = partition
                }
                let transport = client!
                try await transport.capabilities()
                try await pullAll(transport, partition: partition)
                var rounds = 0
                while true {
                    try Task.checkCancellation()
                    let pending = try store.nextOperations(partition)
                    if pending.isEmpty { break }
                    let receipts = try await transport.mutate(pending)
                    try store.acknowledge(receipts, sent: pending, partition: partition)
                    rounds += 1
                    if rounds >= 1_000 { break } // next scheduled catch-up continues a large queue
                }
                try await pullAll(transport, partition: partition)
                try Task.checkCancellation()
                if bridge.currentSelection().partition == partition {
                    try bridge.projectDictations(); try bridge.projectPreferences(); onInboxChanged?()
                }
            } catch is CancellationError { }
            catch CloudSyncError.historyChanged {
                try? bridge.store?.requireBaselineReview(partition)
                lastFailure = CloudSyncError.historyChanged.localizedDescription
            } catch CloudSyncError.signInRequired {
                if activeRunID == runID, bridge.currentSelection().partition == partition {
                    var saved = bridge.currentSelection(); saved.signedIn = false
                    try? bridge.saveSelection(saved); selection = bridge.currentSelection()
                    originDraft = selection.origin; emailDraft = selection.email
                    challenge = nil; codeDraft = ""
                }
                lastFailure = CloudSyncError.signInRequired.localizedDescription
            } catch { lastFailure = error.localizedDescription }
        }
    }
    private func pullAll(_ transport: CloudHTTPClient, partition: String) async throws {
        guard let store = bridge.store else { throw CloudSyncError.storage("unavailable") }
        while true {
            try Task.checkCancellation()
            let page = try await transport.pull(cursor: store.state(partition).cursor)
            try store.apply(page, partition: partition)
            if !page.hasMore { return }
        }
    }
    func reloadBaseline() {
        guard let partition = selection.partition, !busy else { return }
        do { try bridge.store?.resetBaseline(partition); lastFailure = nil; sync() }
        catch { lastFailure = error.localizedDescription; refreshState() }
    }
    func resolve(_ conflict: CloudConflict, choice: CloudSyncStore.ResolutionChoice) {
        guard !busy, let partition = selection.partition, let client else { return }
        busy = true
        Task {
            defer { busy = false; refreshState(); sync() }
            do {
                let remote = try await client.record(collection: conflict.collection, id: conflict.recordId)
                try bridge.store?.resolve(conflict, remote: remote, choice: choice, partition: partition)
                lastFailure = nil
            } catch { lastFailure = error.localizedDescription }
        }
    }
    func deleteRecord(_ row: CloudLocalRecord) {
        guard let partition = selection.partition else { return }
        do { try bridge.store?.capture([CloudLocalEdit(collection: row.collection, recordId: row.recordId, payload: nil)], partition: partition); refreshState(); sync() }
        catch { lastFailure = error.localizedDescription; refreshState() }
    }
    func restoreRecord(_ row: CloudLocalRecord) {
        guard let partition = selection.partition, let payload = row.lastLivePayload else { return }
        do {
            try bridge.store?.capture([CloudLocalEdit(collection: row.collection, recordId: row.recordId,
                payload: payload, restore: true)], partition: partition)
            refreshState(); sync()
        } catch { lastFailure = error.localizedDescription; refreshState() }
    }
    func continueBranch(thread: CloudLocalRecord, leafID: String) {
        guard !AssistantHistoryStore.shared.conversations().contains(where: { $0.turnState == .running }) else {
            lastFailure = "Wait for the running turn to finish before continuing this branch."; refreshState(); return
        }
        let messages = records.filter { $0.collection == .messages && $0.payload?.threadId == thread.recordId && $0.payload != nil }
        let byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.recordId, $0) })
        var chain: [CloudLocalRecord] = []; var next: String? = leafID; var visited: Set<String> = []
        while let id = next, let row = byID[id], !visited.contains(id) {
            visited.insert(id); chain.append(row); next = row.payload?.parentMessageId
        }
        guard next == nil else { lastFailure = "This branch is incomplete. Sync again before continuing."; refreshState(); return }
        let localMessages = chain.reversed().compactMap { row -> AssistantHistoryMessage? in
            guard let payload = row.payload, let text = payload.text,
                  let role = AssistantMessageRole(rawValue: payload.role ?? "") else { return nil }
            return AssistantHistoryMessage(at: payload.createdAt.flatMap(CloudWire.date) ?? Date(), role: role, text: text)
        }
        guard !localMessages.isEmpty else { return }
        let conversation = AssistantHistoryStore.shared.continuePortableBranch(
            title: "\(thread.payload?.title ?? "Cloud thread") · continued", messages: localMessages)
        onContinueConversation?(conversation.id)
    }
    private func refreshState() {
        selection = bridge.currentSelection()
        reviewCount = bridge.reviewCount()
        if let partition = selection.partition, let state = try? bridge.store?.state(partition) {
            records = state.records.values.sorted { $0.recordId < $1.recordId }
            conflicts = state.conflicts.sorted { $0.createdAt < $1.createdAt }
            requiresBaselineReview = state.requiresBaselineReview
            if busy { status = "Syncing · \(state.pendingCount) pending" }
            else if let failure = lastFailure ?? bridge.failure { status = failure }
            else if selection.transport == "local" { status = "Local sync selected · \(state.pendingCount) cloud changes saved here" }
            else if !selection.signedIn { status = "Sign in again · \(state.pendingCount) changes saved here" }
            else if !conflicts.isEmpty { status = "Resolve \(conflicts.count) conflicts · \(state.pendingCount) pending" }
            else if reviewCount > 0 { status = "\(reviewCount) records need review · copies saved here" }
            else if state.pendingCount > 0 { status = "\(state.pendingCount) changes saved here" }
            else if let last = state.lastSuccess, let date = CloudWire.date(last) { status = "Synced · \(date.formatted(date: .omitted, time: .shortened))" }
            else { status = "Ready to sync" }
        } else { status = lastFailure ?? bridge.failure ?? "Local only"; records = []; conflicts = [] }
    }
    func openReviewCopies() { NSWorkspace.shared.open(bridge.reviewDirectory) }
}
