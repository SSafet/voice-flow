import AppKit
import WebKit
import CryptoKit
import MCP

/// Final native composition. T3 owns the workbench, canonical data, queue and
/// runtime. This owner retains only native service handles and launch authority.
@MainActor
final class T3ApplicationHost {
    private weak var app: AppDelegate?
    private let selectedHome: CloudNativeHomeSelection?
    private var process: T3EnvironmentProcess?
    private var broker: T3NativeAuthorityBroker?
    private var account: T3NativeAccountAuthority?
    private var accountTask: Task<T3NativeAccountAuthority, Error>?
    private var tools: T3NativeToolMCP?
    private var toolsTask: Task<T3NativeToolMCP, Error>?
    private var composer: ShellComposerTarget?
    private var nativeBinding: T3NativeToolBinding?
    private var shell: T3ShellWindow?
    private let controlActivity = T3NativeControlActivity()
    private let life = T3NativeToolLifetime()
    private var stopping = false
    private var settings: T3NativeSettings?
    private var backendRevision: String?
    private let shutdown = T3ApplicationShutdown()

    init(app: AppDelegate, selectedHome: CloudNativeHomeSelection?) {
        self.app = app; self.selectedHome = selectedHome
    }

    func start() async throws {
        try life.check()
        guard let app, process == nil else { throw T3NativeAuthorityError.unavailable }
        let runtime = try T3BundledEnvironment()
        let openCode = try T3BundledOpenCode()
        guard let executable = Bundle.main.executableURL else { throw T3EnvironmentProcessError.invalidArtifact }
        // The verified signed executable is the real native backend version.
        backendRevision = try Self.fileDigest(executable)
        settings = try? Self.readSettings() // Invalid execution settings must not block local history.
        let root = VoiceFlowPaths.shared.configRoot.appendingPathComponent("t3-environments", isDirectory: true)
            .appendingPathComponent(selectedHome?.storeKey ?? "local", isDirectory: true)
        let location = try T3ApplicationLocation.open(root: root)
        let process = try T3EnvironmentProcess(runtime: runtime, home: root.appendingPathComponent("home"),
                                              workingDirectory: root, port: location.port,
                                              openCode: openCode)
        self.process = process
        process.onExit = { [weak self] _ in self?.invalidate(message: "The local environment stopped. Reconnect from Settings to reopen it; saved history and input are retained.") }
        let broker = T3NativeAuthorityBroker(ownedEnvironment: { [weak self] in
            try await self?.ownedEnvironment() ?? { throw T3NativeAuthorityError.unavailable }()
        }, leaseProvider: { [weak self] environment in
            guard let self else { throw T3NativeAuthorityError.unavailable }
            return try await self.lease(environment)
        }, isCurrent: { [weak self] lease in await self?.isCurrent(lease) ?? false }, tools: .init(handle: { [weak self] request, environment in
            guard let self else { return .error(statusCode: 503, .internalError("Native host unavailable")) }
            do {
                let tools = try await self.nativeTools(environment)
                return await tools.handle(request, ownedEnvironment: .init(environmentId: environment.environmentID, launchGeneration: environment.generation))
            } catch { return .error(statusCode: 503, .internalError("Native authority unavailable")) }
        }, revoke: { [life] in life.revoke() }, stop: { [weak self] in await self?.stopNativeTools() }))
        self.broker = broker
        let bootstrap = try await broker.start()
        try life.check()
        let connection = try await process.start(nativeAuthority: bootstrap)
        try life.check()
        let source: ShellCapturedInput?
        if let existing = app.shellCapturedInput { source = existing }
        else if let service = CapturedService.shared { source = try app.configureShellInput(service: service) }
        else { source = nil }
        // This UUID belongs only to this isolated root/home; never WebKit.default.
        let store = WKWebsiteDataStore(forIdentifier: location.browserStore)
        let shell = try T3ShellWindow(origin: connection.origin, environmentId: connection.environmentId,
                                      dataStore: store, ruleStoreURL: root.appendingPathComponent("webkit-rules"),
                                      actions: app.shellInputActions(), inputCustody: source?.custody)
        self.shell = shell
        shell.onComposerTargetChanged = { [weak self] target in self?.composer = target; self?.updateOverlayScope() }
        if source != nil { try app.installShellInputWindow(shell) }
        else { app.shellInputWindow = shell }
        try await shell.attach(credential: connection.credential)
        try life.check()
        shell.show()
        status(selectedHome == nil ? "Local history and drafts are ready. Select this Mac’s serving home to enable execution."
               : "Local history and drafts are ready. Execution checks the selected account and serving home when needed.")
    }
    func show() { shell?.show() }
    private func updateOverlayScope() {
        guard let target = composer, target.kind == .thread, let binding = nativeBinding,
              target.environmentId == binding.environment.environmentId else { app?.overlayManager.setActiveSession(nil); return }
        app?.overlayManager.setActiveSession(T3NativeToolPrimitives.overlayOwner(binding: binding, threadId: target.id))
    }
    func ownedEnvironment() throws -> T3AuthorityEnvironmentIdentity {
        try life.check()
        guard let process, !stopping else { throw T3NativeAuthorityError.unavailable }
        return try process.authorityEnvironmentIdentity()
    }
    private func authority() async throws -> T3NativeAccountAuthority {
        try life.check()
        if let account { return account }
        if let accountTask { return try await accountTask.value }
        guard let selectedHome, selectedHome.matches(CloudSyncController.shared.selection) else {
            throw T3NativeAuthorityError.unavailable
        }
        let hostLife = life
        let task = Task { [weak self] in
            try await T3NativeAccountAuthority.connect(destination: .nativeServingHome(id: selectedHome.homeId),
                credentialOwner: { try await CloudSyncController.shared.credentialOwner() },
                ownedEnvironment: { [weak self] in guard let self else { throw T3NativeAuthorityError.unavailable }; return try self.ownedEnvironment() },
                onRevoke: { [weak self, hostLife] in
                    hostLife.revoke()
                    Task { @MainActor in self?.invalidate(message: "Account authority changed. Local history remains available; reconnect explicitly from Settings.") }
                })
        }
        accountTask = task
        defer { accountTask = nil }
        let candidate = try await task.value
        do {
            try life.check()
            guard selectedHome.matches(CloudSyncController.shared.selection) else { throw T3NativeAuthorityError.unavailable }
            account = candidate
            return candidate
        } catch { candidate.revoke(); await candidate.stop(); throw error }
    }
    private func lease(_ environment: T3AuthorityEnvironmentIdentity) async throws -> T3NativeAuthorityLease {
        guard try ownedEnvironment() == environment else { throw T3NativeAuthorityError.unavailable }
        let account = try await authority()
        let lease = try await account.lease(for: environment)
        try life.check()
        guard try ownedEnvironment() == environment, await account.isCurrent(lease) else { throw T3NativeAuthorityError.unavailable }
        return lease
    }
    private func isCurrent(_ lease: T3NativeAuthorityLease) async -> Bool {
        guard (try? life.check()) != nil, let account else { return false }
        return await account.isCurrent(lease)
    }
    private func nativeTools(_ environment: T3AuthorityEnvironmentIdentity) async throws -> T3NativeToolMCP {
        _ = try await lease(environment)
        try life.check()
        if let tools { return tools }
        if let toolsTask { return try await toolsTask.value }
        let task = Task { [self] in try makeNativeTools(environment) }
        toolsTask = task
        defer { toolsTask = nil }
        let candidate = try await task.value
        do { try life.check(); tools = candidate; return candidate }
        catch { candidate.revoke(); await candidate.stop(); throw error }
    }
    private func makeNativeTools(_ environment: T3AuthorityEnvironmentIdentity) throws -> T3NativeToolMCP {
        guard let app, let account, let snapshot = account.currentSnapshot, snapshot.environment == environment,
              let settings, let backendRevision else { throw T3NativeAuthorityError.unavailable }
        let binding = T3NativeToolBinding(environment: .init(environmentId: environment.environmentID, launchGeneration: environment.generation),
                                          ownerId: snapshot.binding.ownerId, deviceId: snapshot.binding.deviceId,
                                          homeId: snapshot.binding.homeId, identityGeneration: snapshot.binding.identityGeneration)
        nativeBinding = binding; updateOverlayScope()
        let policy = AgentPermissionPolicy(profile: settings.runCommands ? .workspace : .observe,
            dial: .init(runCommands: settings.runCommands, reachNetwork: settings.reachNetwork, controlScreen: settings.assistantComputerUse))
        let configuration = try T3NativeConfiguration(binding: binding, settings: settings, decisions: .init(
            contextRead: T3NativeToolDecision(rawValue: policy.decision(for: .contextRead).rawValue) ?? .deny,
            editWorkspace: T3NativeToolDecision(rawValue: policy.decision(for: .editWorkspace).rawValue) ?? .deny,
            shell: T3NativeToolDecision(rawValue: policy.decision(for: .shell).rawValue) ?? .deny))
        let captured = CapturedService.shared
        let primitives = T3NativeToolPrimitives(binding: binding,
            computer: T3NativeDeviceAdapters.computer(screenCapture: app.screenCapture, controlAllowed: { settings.assistantComputerUse }),
            overlays: T3NativeDeviceAdapters.overlays(app.overlayManager),
            captured: captured.map { service in T3NativeDeviceAdapters.captured(index: service.index, root: service.root, progress: { service.progress }) })
        let verify: @Sendable () throws -> Void = { [life] in
            try life.check()
            guard let current = account.currentSnapshot, current.environment == snapshot.environment,
                  current.binding == snapshot.binding, account.permits(current) else { throw T3NativeAuthorityError.unavailable }
        }
        let service = try T3NativeToolService(binding: binding, backendRevision: backendRevision, policyRevision: configuration.policyRevision,
            tools: T3NativeToolCatalog.tools(computer: true, captured: captured != nil, overlay: true),
            backend: .init(authority: { _, action in
                guard (try? verify()) != nil else { return nil }
                let native: AgentCapabilityAction
                switch action {
                case .observe: native = .computerObserve
                case .control: native = .computerControl
                case .capturedRead, .overlayRead: native = .contextRead
                case .overlayWrite: native = .overlayWrite
                }
                let decision = T3NativeToolDecision(rawValue: policy.decision(for: native).rawValue) ?? .deny
                return .init(binding: binding, backendRevision: backendRevision, policyRevision: configuration.policyRevision, decision: decision)
            }, perform: { [controlActivity] call, operation, checkpoint in
                if operation.action == .control { controlActivity.begin() }
                defer { if operation.action == .control { controlActivity.end() } }
                return try await primitives.execute(call, operation, checkpoint)
            }))
        return T3NativeToolMCP(service: service, environment: binding.environment, configuration: {
            try verify(); let value = configuration; try verify(); return value
        }, onTurnClosed: { thread, turn in await primitives.closeTurn(threadId: thread, turnId: turn) })
    }
    /// Immediate permission removal; the local environment/window stay alive so
    /// drafts/history survive account loss. Reconnection always creates a new host.
    func invalidate(message: String) {
        life.revoke(); account?.revoke(); tools?.revoke(); accountTask?.cancel(); toolsTask?.cancel()
        process?.revokeRuntimeAuthority()
        if let broker { Task { await broker.invalidate() } }
        status(message)
    }
    @discardableResult
    nonisolated func stopComputerIfActive() -> Bool {
        guard controlActivity.isActive else { return false }
        life.revoke()
        Task { @MainActor [weak self] in self?.invalidate(message: "Native computer execution stopped by Escape. Reconnect from Settings when ready.") }
        return true
    }
    func identityChanged() {
        // Installing the first shared owner is not a replacement of an admitted identity.
        guard account != nil else { return }
        invalidate(message: "Account changed. Local history remains available; reconnect the selected home from Settings.")
    }
    nonisolated func revokeForSettingsMutation() {
        life.revoke()
        Task { @MainActor [weak self] in self?.invalidate(message: "Execution settings changed. Reconnect from Settings when ready.") }
    }
    func settingsChanged() {
        guard let prior = settings, (try? Self.readSettings()) != prior else { return }
        invalidate(message: "Execution settings changed. Reconnect from Settings to apply them; local drafts are retained.")
    }
    func stop() async {
        await shutdown.drain { [self] in
            stopping = true
            invalidate(message: "Local environment stopped. Saved history and input are retained.")
            let closedShell = shell
            shell?.shutdown(); shell = nil
            if app?.shellInputWindow === closedShell { app?.shellInputWindow = nil }
            let broker = broker, process = process, account = account, accountTask = accountTask
            self.broker = nil; self.process = nil; self.account = nil
            await broker?.stop()
            await process?.stop()
            await account?.stop()
            if let candidate = try? await accountTask?.value { await candidate.stop() }
        }
    }
    private func stopNativeTools() async { await tools?.stop(); tools = nil }
    private func status(_ text: String) { CloudSyncController.shared.nativeEnvironmentStatus = text }
    static func readSettings() throws -> T3NativeSettings {
        let s = UserSettings.shared
        let value = T3NativeSettings(runCommands: s.agentRunCommands, reachNetwork: s.agentReachNetwork,
            assistantComputerUse: s.assistantComputerUse, workspaceRoots: s.agentWorkspaceRoots,
            egressAllow: s.agentEgressAllowedHosts, egressBlock: s.agentEgressBlockedHosts,
            dailyBudgetUSD: s.agentDailyBudgetUSD, model: s.agentModel, reasoningEffort: s.agentReasoningEffort)
        try value.validate(); return value
    }
    private static func fileDigest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
