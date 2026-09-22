import Foundation
import CryptoKit
import Security
import Darwin

enum T3EnvironmentProcessError: Error, LocalizedError {
    case invalidArtifact, invalidHome, homeInUse, alreadyStarted, invalidRuntimeState
    case exited(Int32), startupTimedOut, randomFailure

    var errorDescription: String? {
        switch self {
        case .invalidArtifact: return "The bundled environment failed its integrity check."
        case .invalidHome: return "The environment needs its own writable data directory."
        case .homeInUse: return "This environment is already running. Its existing data was left in place."
        case .alreadyStarted: return "The environment has already been started."
        case .invalidRuntimeState: return "The environment did not confirm its own local address and identity."
        case .exited(let status): return "The environment stopped during startup (exit \(status))."
        case .startupTimedOut: return "The environment did not become ready in time."
        case .randomFailure: return "A private environment credential could not be created."
        }
    }
}

/// The complete upstream archive lives inside the signed app's resource seal.
/// Neither a downloaded page nor a user-edited settings path selects executable code.
struct T3BundledEnvironment {
    let directory: URL
    let supportsNativeAuthorityRevocation: Bool
    var executable: URL { directory.appendingPathComponent("t3") }

    init(bundle: Bundle = .main) throws {
        guard let resources = bundle.resourceURL else { throw T3EnvironmentProcessError.invalidArtifact }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw T3EnvironmentProcessError.invalidArtifact
        }
        let root = resources.appendingPathComponent("T3", isDirectory: true)
        guard root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else {
            throw T3EnvironmentProcessError.invalidArtifact
        }
        struct Receipt: Decodable { let archiveSha256: String; let executableSha256: String; let clientIndexSha256: String; let nativeAuthorityRevocation: String? }
        let receiptURL = root.appendingPathComponent("voiceflow-archive-receipt.json")
        guard let bytes = try? Self.smallFile(receiptURL, limit: 8192),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes),
              Self.isDigest(receipt.archiveSha256) else { throw T3EnvironmentProcessError.invalidArtifact }
        for (relative, expected) in [("t3", receipt.executableSha256), ("client/index.html", receipt.clientIndexSha256)] {
            let file = root.appendingPathComponent(relative)
            guard Self.isDigest(expected),
                  file.resolvingSymlinksInPath().path == file.standardizedFileURL.path,
                  let handle = try? FileHandle(forReadingFrom: file) else { throw T3EnvironmentProcessError.invalidArtifact }
            defer { try? handle.close() }
            var digest = SHA256()
            while let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty { digest.update(data: block) }
            guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
                throw T3EnvironmentProcessError.invalidArtifact
            }
        }
        for name in ["node_modules", "resource-monitor"] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(name).path), !entries.isEmpty else {
                throw T3EnvironmentProcessError.invalidArtifact
            }
        }
        guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("t3").path) else {
            throw T3EnvironmentProcessError.invalidArtifact
        }
        directory = root
        supportsNativeAuthorityRevocation = receipt.nativeAuthorityRevocation == "sigusr2-v1"
    }

    fileprivate static func smallFile(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw T3EnvironmentProcessError.invalidRuntimeState }
        return bytes
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Only the native owner uses this credential, through T3BrowserAuthentication.
/// Deliberately not Codable; log descriptions never include the credential.
struct T3EnvironmentConnection: CustomStringConvertible {
    let origin: T3ShellOrigin
    let environmentId: String
    let credential: String
    var description: String { "T3EnvironmentConnection(\(origin.url.absoluteString))" }
}

/// A Foundation process adapter for T3's existing DesktopBackendBootstrap.
/// T3 retains canonical data, auth, readiness, queue recovery and child runtimes.
/// Hiding the shell does not stop this process. The app owner awaits stop on quit.
@MainActor
final class T3EnvironmentProcess {
    private let runtime: T3BundledEnvironment
    private let home: URL
    private let workingDirectory: URL
    private let port: UInt16
    private var process: Process?
    private var lease: Int32 = -1
    private var ownedHome: (device: dev_t, inode: ino_t)?
    private var connection: T3EnvironmentConnection?
    private var launchGeneration: UUID?
    private var authorityIdentity: T3AuthorityEnvironmentIdentity?
    private var starting = false
    private var nativeAuthorityConfigured = false
    private var runtimeAuthorityRevoked = false
    var onExit: ((Int32) -> Void)?

    init(runtime: T3BundledEnvironment, home: URL, workingDirectory: URL, port: UInt16) throws {
        guard port > 0, home.isFileURL, workingDirectory.isFileURL else { throw T3EnvironmentProcessError.invalidHome }
        let canonical = home.standardizedFileURL.resolvingSymlinksInPath()
        let liveT3 = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3").resolvingSymlinksInPath()
        guard canonical.path != liveT3.path, !canonical.path.hasPrefix(liveT3.path + "/"),
              canonical.path != FileManager.default.homeDirectoryForCurrentUser.path,
              canonical.path != "/", canonical.path != runtime.directory.path,
              !canonical.path.hasPrefix(runtime.directory.path + "/"),
              home.standardizedFileURL.path == canonical.path else { throw T3EnvironmentProcessError.invalidHome }
        self.runtime = runtime
        self.home = canonical
        self.workingDirectory = workingDirectory
        self.port = port
    }

    deinit {
        // This is the exact Process captured at spawn, never a PID read from disk.
        if let process, process.isRunning { process.terminate() }
        if lease >= 0 { Darwin.close(lease) }
    }

    func start(timeout: TimeInterval = 30, nativeAuthority: T3NativeAuthorityBootstrap? = nil) async throws -> T3EnvironmentConnection {
        guard nativeAuthority == nil || runtime.supportsNativeAuthorityRevocation else { throw T3EnvironmentProcessError.invalidArtifact }
        guard !starting, process == nil, connection == nil else { throw T3EnvironmentProcessError.alreadyStarted }
        starting = true
        defer { starting = false }
        try acquireHome()
        do {
            try refuseExistingProcess()
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw T3EnvironmentProcessError.randomFailure }
            let credential = random.map { String(format: "%02x", $0) }.joined()
            // This is the upstream contracts/src/desktopBootstrap.ts envelope.
            // Explicit flags prevent ambient T3CODE_* settings overriding its home.
            var bootstrap: [String: Any] = [
                "mode": "desktop", "noBrowser": true, "port": Int(port),
                "t3Home": home.path, "host": "127.0.0.1", "desktopBootstrapToken": credential,
                "tailscaleServeEnabled": false, "tailscaleServePort": 443,
            ]
            if let nativeAuthority {
                bootstrap["atikaNativeAuthority"] = ["origin": nativeAuthority.origin, "credential": nativeAuthority.credential]
            }
            var input = try JSONSerialization.data(withJSONObject: bootstrap)
            input.append(10)
            let pipe = Pipe()
            guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                throw T3EnvironmentProcessError.invalidRuntimeState
            }
            let child = Process()
            child.executableURL = runtime.executable
            child.currentDirectoryURL = workingDirectory
            child.arguments = ["start", "--bootstrap-fd", "0", "--base-dir", home.path, "--mode", "desktop", "--host", "127.0.0.1", "--port", String(port), "--no-browser"]
            let allowed = Set(["HOME", "USER", "LOGNAME", "SHELL", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "TERM", "COLORTERM"])
            child.environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
            child.standardInput = pipe
            // T3 writes its own bounded logs beneath this explicit home. Do not
            // forward potentially sensitive startup output to the web or app log.
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { [weak self] finished in
                let status = finished.terminationStatus
                Task { @MainActor [weak self] in self?.didExit(finished, status: status) }
            }
            try child.run()
            process = child
            nativeAuthorityConfigured = nativeAuthority != nil
            runtimeAuthorityRevoked = false
            launchGeneration = UUID()
            authorityIdentity = nil
            try pipe.fileHandleForWriting.write(contentsOf: input)
            try pipe.fileHandleForWriting.close()
            let deadline = Date().addingTimeInterval(max(0.1, min(timeout, 120)))
            while Date() < deadline {
                try Task.checkCancellation()
                guard child.isRunning else { throw T3EnvironmentProcessError.exited(child.terminationStatus) }
                if let ready = try readReady(child: child, credential: credential) {
                    connection = ready
                    return ready
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw T3EnvironmentProcessError.startupTimedOut
        } catch {
            await stop()
            throw error
        }
    }

    /// The matching native-bootstrap server reserves SIGUSR2 to revoke admitted
    /// turns while preserving its local history server. Never read a PID from disk.
    @discardableResult
    func revokeRuntimeAuthority() -> Bool {
        guard connection != nil, nativeAuthorityConfigured, !runtimeAuthorityRevoked,
              runtime.supportsNativeAuthorityRevocation, let child = process, child.isRunning else { return false }
        guard Darwin.kill(child.processIdentifier, SIGUSR2) == 0 else { return false }
        runtimeAuthorityRevoked = true
        return true
    }

    func stop() async {
        connection = nil
        nativeAuthorityConfigured = false
        launchGeneration = nil
        authorityIdentity = nil
        guard let child = process else { releaseHome(); return }
        // waitUntilExit runs away from the main actor; the exact owned Process
        // remains retained until reaped, including cancellation of the caller.
        await Task.detached {
            if child.isRunning { child.terminate() }
            let deadline = Date().addingTimeInterval(5)
            while child.isRunning && Date() < deadline { try? await Task.sleep(for: .milliseconds(25)) }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
        }.value
        if process === child { process = nil; releaseHome() }
    }

    private func didExit(_ child: Process, status: Int32) {
        guard process === child else { return }
        process = nil
        connection = nil
        nativeAuthorityConfigured = false
        launchGeneration = nil
        authorityIdentity = nil
        releaseHome()
        onExit?(status)
    }

    /// Available once the owned child's ServerEnvironmentIdentity has established
    /// its file, even while provider hydration is waiting for the native broker.
    /// The request's environment ID is deliberately not an input to this method.
    func authorityEnvironmentIdentity() throws -> T3AuthorityEnvironmentIdentity {
        guard lease >= 0, let child = process, child.isRunning, let launchGeneration else {
            throw T3NativeAuthorityError.unavailable
        }
        // Open each component relative to an owned directory descriptor. A symlink,
        // FIFO, wrong owner, or replaced directory cannot redirect this read.
        let rootFD = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw T3NativeAuthorityError.unavailable }
        defer { Darwin.close(rootFD) }
        let dataFD = openat(rootFD, "userdata", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dataFD >= 0 else { throw T3NativeAuthorityError.unavailable }
        defer { Darwin.close(dataFD) }
        for descriptor in [rootFD, dataFD] {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                throw T3NativeAuthorityError.unavailable
            }
        }
        var rootInfo = stat()
        var lockedInfo = stat()
        var namedLock = stat()
        guard let ownedHome, fstat(rootFD, &rootInfo) == 0,
              rootInfo.st_dev == ownedHome.device, rootInfo.st_ino == ownedHome.inode,
              fstat(lease, &lockedInfo) == 0,
              fstatat(rootFD, ".voiceflow-owner.lock", &namedLock, AT_SYMLINK_NOFOLLOW) == 0,
              namedLock.st_dev == lockedInfo.st_dev, namedLock.st_ino == lockedInfo.st_ino else {
            throw T3NativeAuthorityError.unavailable
        }
        let identityFD = openat(dataFD, "environment-id", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard identityFD >= 0 else { throw T3NativeAuthorityError.unavailable }
        let handle = FileHandle(fileDescriptor: identityFD, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(identityFD, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, (1...512).contains(info.st_size),
              let bytes = try handle.read(upToCount: 513), bytes.count <= 512,
              let raw = String(data: bytes, encoding: .utf8) else { throw T3NativeAuthorityError.unavailable }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              child.isRunning, self.process === child else { throw T3NativeAuthorityError.unavailable }
        let identity = T3AuthorityEnvironmentIdentity(environmentID: value, generation: launchGeneration)
        guard authorityIdentity == nil || authorityIdentity == identity,
              connection == nil || connection?.environmentId == value else { throw T3NativeAuthorityError.unavailable }
        authorityIdentity = identity
        return identity
    }

    private func acquireHome() throws {
        // Foundation can spell /private/tmp as /tmp only after a previously
        // missing directory exists. Compare both sides in the same form so a
        // successful first launch can restart, while other symlinks still fail.
        guard home.resolvingSymlinksInPath().path == home.standardizedFileURL.path,
              home.appendingPathComponent("userdata").resolvingSymlinksInPath().path == home.appendingPathComponent("userdata").standardizedFileURL.path else {
            throw T3EnvironmentProcessError.invalidHome
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(home.path, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw T3EnvironmentProcessError.invalidHome }
        let fd = open(home.appendingPathComponent(".voiceflow-owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw T3EnvironmentProcessError.invalidHome }
        var lockInfo = stat()
        guard fstat(fd, &lockInfo) == 0, lockInfo.st_uid == getuid(), (lockInfo.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd); throw T3EnvironmentProcessError.invalidHome
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw T3EnvironmentProcessError.homeInUse }
        lease = fd
        ownedHome = (info.st_dev, info.st_ino)
    }

    private func releaseHome() {
        if lease >= 0 { Darwin.close(lease); lease = -1 }
        ownedHome = nil
    }

    private struct RuntimeState: Decodable {
        let version: Int; let pid: Int32; let port: Int; let origin: String
        let host: String?; let devUrl: String?
    }
    private var stateURL: URL { home.appendingPathComponent("userdata/server-runtime.json") }

    private func refuseExistingProcess() throws {
        var info = stat()
        if lstat(stateURL.path, &info) != 0 {
            if errno == ENOENT { return }
            throw T3EnvironmentProcessError.invalidRuntimeState
        }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              let bytes = try? T3BundledEnvironment.smallFile(stateURL, limit: 16_384),
              let state = try? JSONDecoder().decode(RuntimeState.self, from: bytes), state.version == 1, state.pid > 0 else {
            throw T3EnvironmentProcessError.invalidRuntimeState
        }
        if Darwin.kill(state.pid, 0) == 0 || errno == EPERM { throw T3EnvironmentProcessError.homeInUse }
    }

    private func readReady(child: Process, credential: String) throws -> T3EnvironmentConnection? {
        guard let bytes = try? T3BundledEnvironment.smallFile(stateURL, limit: 16_384),
              let state = try? JSONDecoder().decode(RuntimeState.self, from: bytes), state.pid == child.processIdentifier else { return nil }
        guard state.version == 1, state.port == Int(port), state.host == "127.0.0.1", state.devUrl == nil,
              state.origin == "http://127.0.0.1:\(port)", let url = URL(string: state.origin) else { throw T3EnvironmentProcessError.invalidRuntimeState }
        guard let identity = try? authorityEnvironmentIdentity() else { throw T3EnvironmentProcessError.invalidRuntimeState }
        return T3EnvironmentConnection(origin: try T3ShellOrigin(url), environmentId: identity.environmentID, credential: credential)
    }
}
