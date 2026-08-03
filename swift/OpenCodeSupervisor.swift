import Foundation
import Darwin
import Security

private final class OpenCodeProcessLog {
    private static let maxBytes = 512 * 1_024
    private let lock = NSLock()
    private let url: URL
    private let secrets: [String]
    private var tailText = ""

    init(url: URL, secrets: [String]) {
        self.url = url
        self.secrets = secrets.filter { !$0.isEmpty }
    }

    func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.consume(data)
        }
    }

    func stop(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    func tail(limit: Int = 4_096) -> String {
        lock.withLock { String(tailText.suffix(limit)) }
    }

    private func consume(_ data: Data) {
        guard var text = String(data: data, encoding: .utf8) else { return }
        for secret in secrets { text = text.replacingOccurrences(of: secret, with: "[REDACTED]") }
        text = AgentSecretPolicy.redacted(text)
        lock.withLock {
            tailText = String((tailText + text).suffix(16_384))
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let existing = (try? Data(contentsOf: url)) ?? Data()
                var next = existing + Data(text.utf8)
                if next.count > Self.maxBytes {
                    next = Data(next.suffix(Self.maxBytes / 2))
                }
                try next.write(to: url, options: .atomic)
            } catch {
                // Runtime logging must never take down the harness.
            }
        }
    }
}

struct OpenCodeConnection: Equatable {
    let baseURL: URL
    let username: String
    let password: String
    let version: String
    let toolEndpoint: URL?
    let toolToken: String?

    init(baseURL: URL, username: String, password: String, version: String,
         toolEndpoint: URL? = nil, toolToken: String? = nil) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.version = version
        self.toolEndpoint = toolEndpoint
        self.toolToken = toolToken
    }

    var authorizationHeader: String {
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(credentials)"
    }
}

enum OpenCodeSupervisorError: LocalizedError {
    case binaryNotFound
    case manifestInvalid
    case versionMismatch(expected: String, actual: String)
    case portUnavailable
    case modelUnavailable(String)
    case launchFailed(String)
    case healthTimeout(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "OpenCode runtime not found. Reinstall Voice Flow or install the pinned developer runtime."
        case .manifestInvalid:
            return "Voice Flow's OpenCode version manifest is missing or invalid."
        case .versionMismatch(let expected, let actual):
            return "OpenCode version mismatch: Voice Flow requires \(expected), found \(actual)."
        case .portUnavailable:
            return "Could not allocate a private loopback port for OpenCode."
        case .modelUnavailable(let model):
            return "OpenCode could not configure the selected model \(model)."
        case .launchFailed(let detail):
            return "OpenCode failed to launch: \(detail)"
        case .healthTimeout(let detail):
            return "OpenCode did not become healthy: \(detail)"
        }
    }
}

protocol OpenCodeServing: AnyObject {
    func connection(for profile: AgentTrustProfile) async throws -> OpenCodeConnection
    func acquireConnection(for profile: AgentTrustProfile,
                           modelID: String?) async throws -> OpenCodeConnection
    func releaseConnection(for profile: AgentTrustProfile) async
    func status(for profile: AgentTrustProfile) async -> AgentRuntimeStatus
    func stop(profile: AgentTrustProfile) async
    func stopAll() async
}

extension OpenCodeServing {
    func acquireConnection(for profile: AgentTrustProfile,
                           modelID: String?) async throws -> OpenCodeConnection {
        try await connection(for: profile)
    }
    func releaseConnection(for profile: AgentTrustProfile) async {}
}

actor OpenCodeSupervisor: OpenCodeServing {
    static let shared = OpenCodeSupervisor()

    private struct Manifest: Decodable {
        struct Asset: Decodable {
            let url: String
            let archiveSHA256: String
            let binarySHA256: String
        }
        struct Fallback: Decodable {
            let path: String
            let sha256: String?
        }
        let version: String
        let assets: [String: Asset]
        let developerFallbacks: [String: Fallback]
    }

    private struct InstalledManifest: Decodable {
        let version: String
        let architecture: String
        let sourceBinarySHA256: String
        let installedBinarySHA256: String
    }

    private struct Instance {
        let process: Process
        let connection: OpenCodeConnection
        let root: URL
        let output: Pipe
        let log: OpenCodeProcessLog
        let gateway: ModelGatewayServer
        let toolServer: AgentToolServer
        let egress: EgressProxyServer?
        let allowedModels: Set<String>
        /// The containment this process was launched under. A profile is fixed
        /// at exec time, so a changed policy means a new process — never a
        /// running one silently keeping the old, looser boundary.
        let sandboxPolicy: AgentSandboxPolicy
    }

    private var instances: [AgentTrustProfile: Instance] = [:]
    private var startTasks: [AgentTrustProfile: Task<OpenCodeConnection, Error>] = [:]
    private var restartFailures: [AgentTrustProfile: (count: Int, notBefore: Date)] = [:]
    private var activeConnections: [AgentTrustProfile: Int] = [:]
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func status(for profile: AgentTrustProfile) async -> AgentRuntimeStatus {
        guard let instance = instances[profile] else {
            return AgentRuntimeStatus(health: .stopped, version: nil, detail: "Starts on demand")
        }
        guard instance.process.isRunning else {
            return AgentRuntimeStatus(
                health: .crashed, version: instance.connection.version,
                detail: "The supervised process exited")
        }
        if await isHealthy(instance.connection) {
            return AgentRuntimeStatus(
                health: .healthy, version: instance.connection.version, detail: nil)
        }
        return AgentRuntimeStatus(
            health: .degraded, version: instance.connection.version,
            detail: "Health check failed")
    }

    func connection(for profile: AgentTrustProfile) async throws -> OpenCodeConnection {
        if let instance = instances[profile], instance.process.isRunning,
           await isHealthy(instance.connection) {
            return instance.connection
        }
        if let task = startTasks[profile] {
            return try await task.value
        }
        let task = Task { try await self.startConnection(for: profile) }
        startTasks[profile] = task
        do {
            let connection = try await task.value
            startTasks.removeValue(forKey: profile)
            return connection
        } catch {
            startTasks.removeValue(forKey: profile)
            throw error
        }
    }

    /// A model catalog can refresh while long-running agents are active. A
    /// newly selected model waits for the current finite turns to drain, then
    /// rolls the shared trust-profile process once with the expanded catalog;
    /// existing turns are never killed just to apply a picker refresh.
    func acquireConnection(for profile: AgentTrustProfile,
                           modelID: String?) async throws -> OpenCodeConnection {
        while true {
            try Task.checkCancellation()
            let desiredSandbox = Self.sandboxPolicy(profile: profile)
            if let instance = instances[profile], instance.process.isRunning,
               (modelID.map { !instance.allowedModels.contains($0) } ?? false)
                 || instance.sandboxPolicy != desiredSandbox {
                // Same drain-then-roll rule the model catalog already uses: a
                // tightened dial or a new granted root must not kill turns that
                // are mid-flight, but it must apply before the next one starts.
                if activeConnections[profile, default: 0] > 0 {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                await stopInstance(profile: profile)
            }
            let value = try await connection(for: profile)
            if let modelID,
               instances[profile]?.allowedModels.contains(modelID) != true {
                throw OpenCodeSupervisorError.modelUnavailable(modelID)
            }
            activeConnections[profile, default: 0] += 1
            return value
        }
    }

    func releaseConnection(for profile: AgentTrustProfile) async {
        activeConnections[profile] = max(0, activeConnections[profile, default: 0] - 1)
    }

    private func startConnection(for profile: AgentTrustProfile) async throws
        -> OpenCodeConnection {
        await stopInstance(profile: profile)
        try Task.checkCancellation()
        if let failure = restartFailures[profile], failure.notBefore > Date() {
            let delay = failure.notBefore.timeIntervalSinceNow
            try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
        }
        do {
            let connection = try await start(profile: profile)
            restartFailures.removeValue(forKey: profile)
            return connection
        } catch {
            let count = min((restartFailures[profile]?.count ?? 0) + 1, 8)
            let seconds = min(30.0, 0.25 * pow(2.0, Double(count - 1)))
            restartFailures[profile] = (count, Date().addingTimeInterval(seconds))
            throw error
        }
    }

    func stop(profile: AgentTrustProfile) async {
        startTasks.removeValue(forKey: profile)?.cancel()
        await stopInstance(profile: profile)
        activeConnections[profile] = 0
    }

    private func stopInstance(profile: AgentTrustProfile) async {
        guard let instance = instances.removeValue(forKey: profile) else { return }
        instance.gateway.stop()
        instance.toolServer.stop()
        instance.egress?.stop()
        if instance.process.isRunning {
            let pid = instance.process.processIdentifier
            let descendants = Self.descendants(of: pid)
            descendants.reversed().forEach { kill($0, SIGTERM) }
            kill(pid, SIGTERM)
            for _ in 0..<20 where instance.process.isRunning {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            descendants.reversed().forEach { kill($0, SIGKILL) }
            if instance.process.isRunning { kill(pid, SIGKILL) }
        }
        instance.log.stop(pipe: instance.output)
        try? FileManager.default.removeItem(
            at: instance.root.appendingPathComponent("process.pid"))
    }

    func stopAll() async {
        let profiles = Set(instances.keys).union(startTasks.keys)
        for profile in profiles { await stop(profile: profile) }
        restartFailures.removeAll()
    }

    private func start(profile: AgentTrustProfile) async throws -> OpenCodeConnection {
        try Task.checkCancellation()
        let manifest = try loadManifest()
        let binary = try resolveBinary(manifest: manifest)
        let actualVersion = try binaryVersion(binary)
        guard actualVersion == manifest.version else {
            throw OpenCodeSupervisorError.versionMismatch(
                expected: manifest.version, actual: actualVersion)
        }
        guard let port = Self.allocateLoopbackPort() else {
            throw OpenCodeSupervisorError.portUnavailable
        }

        let credentialSnapshot = ModelGatewayCredentials.shared.snapshot()
        let allowedModels = credentialSnapshot.allowedModels
        let refreshedCatalog: OpenRouterModelCatalogResult
        if allowedModels.isEmpty {
            refreshedCatalog = OpenRouterModelCatalogResult(
                models: [], source: .fallback, fetchedAt: nil, warning: nil)
        } else {
            refreshedCatalog = await OpenRouterModelCatalog.shared.refresh(
                baseURL: credentialSnapshot.upstreamBaseURL,
                apiKey: credentialSnapshot.apiKey,
                fallbackIDs: allowedModels)
        }

        let username = "voice-flow"
        let password = try Self.randomSecret()
        let gateway = ModelGatewayServer()
        let gatewayConnection = try gateway.start()
        let toolServer = AgentToolServer()
        let toolConnection: AgentToolServerConnection
        do {
            toolConnection = try toolServer.start()
        } catch {
            gateway.stop()
            throw error
        }
        let root = VoiceFlowPaths.shared.directory("runtime/opencode/\(profile.rawValue)")
        let configRoot = root.appendingPathComponent("config", isDirectory: true)
        let dataRoot = root.appendingPathComponent("data", isDirectory: true)
        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        for directory in [configRoot, dataRoot, cacheRoot, stateRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Custom OpenAI-compatible models default to text-only in OpenCode's
        // v1 API unless their input modalities are declared explicitly. Voice
        // Flow screenshots are JPEG data URLs, so advertise the capability in
        // the generated, process-private provider catalog.
        let catalog = Dictionary(uniqueKeysWithValues:
            refreshedCatalog.models.map { ($0.id, $0) })
        let models = Dictionary(uniqueKeysWithValues: allowedModels.map { id in
            let model = catalog[id] ?? .fallback(id: id)
            return (id, [
                "name": model.name,
                "modalities": [
                    "input": model.supportsImages ? ["text", "image"] : ["text"],
                    "output": ["text"],
                ],
                "limit": [
                    "context": model.openCodeContextLimit,
                    "output": model.openCodeOutputLimit,
                ],
            ] as [String: Any])
        })
        let dial = AgentSandboxSettings.shared.snapshot().dial
        var permission = AgentPermissionPolicy(profile: profile, dial: dial)
            .openCodeConfiguration(selectedSkills: [], readableExternalRoots: [])
        // The server is rooted in an empty XDG home and every Assistant turn
        // atomically replaces that Assistant's .opencode/skills projection.
        // OpenCode permission rules are process-wide, so discovery isolation—not
        // a stale global name list—is the enforceable selected-skill boundary.
        permission["skill"] = "allow"
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "share": "disabled",
            "permission": permission,
            "provider": [
                "openrouter": [
                    "name": "OpenRouter via Voice Flow",
                    "npm": "@ai-sdk/openai-compatible",
                    "models": models,
                    "options": [
                        "baseURL": gatewayConnection.baseURL.absoluteString,
                        "apiKey": gatewayConnection.token,
                    ],
                ],
            ],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let configText = String(data: configData, encoding: .utf8) ?? "{}"
        let configURL = root.appendingPathComponent("voice-flow-opencode.json")
        try configData.write(to: configURL, options: .atomic)

        let homeRoot = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeRoot, withIntermediateDirectories: true)

        // Egress: the sandbox denies every non-loopback connection, so this
        // proxy is the only way out and the dial's network switch is simply
        // whether it exists. Nothing to bypass — there is no second route.
        var egress: EgressProxyServer?
        var proxyConnection: EgressProxyConnection?
        if dial.reachNetwork {
            let server = EgressProxyServer(policy: {
                let live = AgentSandboxSettings.shared.snapshot()
                return EgressPolicy(allowedHosts: live.egressAllowedHosts,
                                    blockedHosts: live.egressBlockedHosts)
            })
            do {
                proxyConnection = try server.start()
                egress = server
            } catch {
                gateway.stop()
                toolServer.stop()
                egress?.stop()
                throw error
            }
        }

        let sandboxPolicy = Self.sandboxPolicy(profile: profile)
        let sandboxPrefix: [String]
        do {
            let profileURL = root.appendingPathComponent("sandbox.sb")
            guard let prefix = try AgentSandbox.launchPrefix(
                policy: sandboxPolicy, profileURL: profileURL) else {
                // Refusing to start beats starting unconfined: a runtime that
                // quietly loses its boundary is the failure this ticket exists
                // to prevent.
                gateway.stop(); toolServer.stop(); egress?.stop()
                throw OpenCodeSupervisorError.launchFailed(
                    "sandbox-exec is unavailable, so the agent cannot be contained")
            }
            sandboxPrefix = prefix
        } catch let error as OpenCodeSupervisorError {
            throw error
        } catch {
            gateway.stop(); toolServer.stop(); egress?.stop()
            throw OpenCodeSupervisorError.launchFailed(
                "could not write the sandbox profile: \(error.localizedDescription)")
        }

        let process = Process()
        let serveArguments = [
            binary, "--pure", "serve", "--hostname", "127.0.0.1",
            "--port", String(port), "--print-logs", "--log-level", "WARN",
        ]
        // argv[0] is sandbox-exec; the runtime binary becomes its argument, so
        // the profile is applied by the kernel before opencode's first
        // instruction and is inherited by everything it spawns.
        process.executableURL = URL(fileURLWithPath: sandboxPrefix[0])
        process.arguments = Array(sandboxPrefix.dropFirst()) + serveArguments
        process.currentDirectoryURL = root
        var environment = Self.sanitizedEnvironment()
        environment["HOME"] = homeRoot.path
        if let proxyConnection {
            environment["HTTPS_PROXY"] = proxyConnection.proxyURL
            environment["HTTP_PROXY"] = proxyConnection.proxyURL
            environment["https_proxy"] = proxyConnection.proxyURL
            environment["http_proxy"] = proxyConnection.proxyURL
            // The loopback services must not be proxied through the proxy.
            environment["NO_PROXY"] = "127.0.0.1,localhost"
            environment["no_proxy"] = "127.0.0.1,localhost"
        }
        environment["XDG_CONFIG_HOME"] = configRoot.path
        environment["XDG_DATA_HOME"] = dataRoot.path
        environment["XDG_CACHE_HOME"] = cacheRoot.path
        environment["XDG_STATE_HOME"] = stateRoot.path
        environment["OPENCODE_CONFIG"] = configURL.path
        environment["OPENCODE_CONFIG_DIR"] = configRoot.path
        environment["OPENCODE_CONFIG_CONTENT"] = configText
        environment["OPENCODE_SERVER_USERNAME"] = username
        environment["OPENCODE_SERVER_PASSWORD"] = password
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "true"
        environment["OPENCODE_DISABLE_CLAUDE_CODE_PROMPT"] = "true"
        process.environment = environment
        let output = Pipe()
        let log = OpenCodeProcessLog(
            url: root.appendingPathComponent("logs/opencode.log"),
            secrets: [password, gatewayConnection.token, toolConnection.token])
        log.attach(to: output)
        process.standardOutput = output
        process.standardError = output

        if Task.isCancelled {
            log.stop(pipe: output)
            gateway.stop()
            toolServer.stop()
            egress?.stop()
            throw CancellationError()
        }

        do {
            try process.run()
        } catch {
            log.stop(pipe: output)
            gateway.stop()
            toolServer.stop()
            egress?.stop()
            throw OpenCodeSupervisorError.launchFailed(error.localizedDescription)
        }
        do {
            try String(process.processIdentifier).write(
                to: root.appendingPathComponent("process.pid"),
                atomically: true, encoding: .utf8)
        } catch {
            kill(process.processIdentifier, SIGTERM)
            log.stop(pipe: output)
            gateway.stop()
            toolServer.stop()
            egress?.stop()
            throw OpenCodeSupervisorError.launchFailed(
                "could not record runtime process ownership")
        }

        let connection = OpenCodeConnection(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            username: username, password: password, version: actualVersion,
            toolEndpoint: toolConnection.endpoint, toolToken: toolConnection.token)
        instances[profile] = Instance(
            process: process, connection: connection, root: root,
            output: output, log: log,
            gateway: gateway, toolServer: toolServer, egress: egress,
            allowedModels: allowedModels, sandboxPolicy: sandboxPolicy)

        for _ in 0..<60 {
            if Task.isCancelled {
                await stopInstance(profile: profile)
                throw CancellationError()
            }
            if !process.isRunning {
                let detail = log.tail()
                instances.removeValue(forKey: profile)
                log.stop(pipe: output)
                gateway.stop()
                toolServer.stop()
                egress?.stop()
                throw OpenCodeSupervisorError.launchFailed(
                    detail.isEmpty ? "process exited before health check" : detail)
            }
            if await isHealthy(connection) { return connection }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let detail = log.tail()
        await stopInstance(profile: profile)
        throw OpenCodeSupervisorError.healthTimeout(
            detail.isEmpty ? "15 second startup timeout" : detail)
    }

    private func isHealthy(_ connection: OpenCodeConnection) async -> Bool {
        var request = URLRequest(url: connection.baseURL.appendingPathComponent("global/health"))
        request.timeoutInterval = 2
        request.setValue(connection.authorizationHeader, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["healthy"] as? Bool == true
                && json["version"] as? String == connection.version
        } catch {
            return false
        }
    }

    private func loadManifest() throws -> Manifest {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "versions", withExtension: "json", subdirectory: "Runtime/OpenCode"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("runtime/opencode/versions.json"),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: candidate),
               let manifest = try? JSONDecoder().decode(Manifest.self, from: data) {
                return manifest
            }
        }
        throw OpenCodeSupervisorError.manifestInvalid
    }

    private func resolveBinary(manifest: Manifest) throws -> String {
        if let bundled = Bundle.main.url(
            forResource: "opencode", withExtension: nil, subdirectory: "Runtime/OpenCode"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            guard let sourceExpected = manifest.assets[Self.architecture]?.binarySHA256,
                  let installed = loadInstalledManifest(),
                  installed.version == manifest.version,
                  installed.architecture == Self.architecture,
                  installed.sourceBinarySHA256 == sourceExpected,
                  Self.sha256(path: bundled.path) == installed.installedBinarySHA256 else {
                throw OpenCodeSupervisorError.launchFailed(
                    "bundled OpenCode binary failed its sealed installation check")
            }
            return bundled.path
        }
        let architecture = Self.architecture
        if let fallback = manifest.developerFallbacks[architecture],
           FileManager.default.isExecutableFile(atPath: fallback.path) {
            if let expected = fallback.sha256,
               Self.sha256(path: fallback.path) != expected {
                throw OpenCodeSupervisorError.launchFailed(
                    "developer OpenCode binary failed its SHA-256 check")
            }
            return fallback.path
        }
        throw OpenCodeSupervisorError.binaryNotFound
    }

    private func loadInstalledManifest() -> InstalledManifest? {
        guard let url = Bundle.main.url(
            forResource: "installed", withExtension: "json",
            subdirectory: "Runtime/OpenCode"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(InstalledManifest.self, from: data)
    }

    private func binaryVersion(_ path: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch {
            throw OpenCodeSupervisorError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0, !version.isEmpty else {
            throw OpenCodeSupervisorError.launchFailed("could not read runtime version")
        }
        return version
    }

    private static var architecture: String {
#if arch(arm64)
        return "arm64"
#else
        return "x86_64"
#endif
    }

    private static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OpenCodeSupervisorError.launchFailed("could not generate runtime credentials")
        }
        return Data(bytes).base64EncodedString()
    }

    /// The containment for one trust profile, derived from the user's granted
    /// roots and dial (VF-59). Pure and deterministic so `acquireConnection`
    /// can compare it against what a running process was launched with.
    static func sandboxPolicy(profile: AgentTrustProfile) -> AgentSandboxPolicy {
        let settings = AgentSandboxSettings.shared.snapshot()
        let dial = settings.dial
        let runtimeRoot = VoiceFlowPaths.shared
            .directory("runtime/opencode/\(profile.rawValue)")
        let workspaces = settings.workspaceRoots.compactMap { raw -> URL? in
            let expanded = NSString(string: raw).expandingTildeInPath
            guard !expanded.isEmpty, expanded.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        // Assistant folders stay writable regardless of the granted list —
        // memory, ledger and skills live there and are the agent's own state.
        let assistantRoot = VoiceFlowPaths.shared.directory("assistants")
        var temporary: [URL] = []
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] {
            temporary.append(URL(fileURLWithPath: tmp))
        }
        temporary.append(URL(fileURLWithPath: "/private/var/folders"))
        temporary.append(URL(fileURLWithPath: "/private/tmp"))
        return AgentSandboxPolicy(
            workspaceRoots: workspaces,
            runtimeRoots: [runtimeRoot, assistantRoot],
            temporaryRoots: temporary,
            allowShell: dial.runCommands,
            allowNetwork: dial.reachNetwork)
    }

    static func sanitizedEnvironment(
        source: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let allowlist = [
            "PATH", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY",
        ]
        var result: [String: String] = [:]
        for key in allowlist where source[key] != nil { result[key] = source[key] }
        return result
    }

    private static func allocateLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard read == 0 else { return nil }
        return UInt16(bigEndian: resolved.sin_port)
    }

    private static func sha256(path: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.split(separator: " ").first.map(String.init)
    }

    private static func descendants(of parent: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [parent]
        var seen: Set<pid_t> = [parent]
        while let current = queue.first {
            queue.removeFirst()
            var children = [pid_t](repeating: 0, count: 128)
            let bytes = proc_listchildpids(
                current, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            let count = min(Int(bytes) / MemoryLayout<pid_t>.size, children.count)
            for child in children.prefix(count) where child > 0 && !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }
}
