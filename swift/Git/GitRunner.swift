import Foundation
import Darwin

/// What git printed and how it ended. Standard output is kept as bytes because
/// a diff can carry anything; standard error is text because every message a
/// person reads is text.
struct GitOutput: Equatable, Sendable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: String

    var text: String {
        String(decoding: standardOutput, as: UTF8.self)
    }
}

/// Why a run did not produce a normal result.
enum GitFailure: Error, Equatable {
    case unavailable(String)
    case timedOut(seconds: Double)
    case failed(exitCode: Int32, message: String)
}

/// The only place in this package that starts a process (06 §3.16). It decides
/// the argument list, the environment, the working folder and the time limit
/// once, so no caller has to.
struct GitRunner: Sendable {
    static let defaultTimeout: Double = 20

    /// `posix_spawn_file_actions_addchdir_np` is deprecated as of macOS 26 and
    /// its replacement needs macOS 26, but this app runs from macOS 14, so the
    /// function is resolved by name instead of referenced directly. That keeps
    /// the build free of a deprecation warning under either SDK.
    private typealias AddChangeDirectoryFunction =
        @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t?>, UnsafePointer<CChar>?) -> Int32

    private static let addChangeDirectory: AddChangeDirectoryFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "posix_spawn_file_actions_addchdir_np") else {
            return nil
        }
        return unsafeBitCast(symbol, to: AddChangeDirectoryFunction.self)
    }()

    let program: GitProgram
    let timeout: Double

    init(program: GitProgram, timeout: Double = GitRunner.defaultTimeout) {
        self.program = program
        self.timeout = timeout
    }

    func run(_ arguments: [String], in folder: URL, query: Bool = false,
             clientValues: [String] = [], paths: [String] = [],
             indexFile: URL? = nil, environment extra: [String: String] = [:])
        -> Result<GitOutput, GitFailure> {
        var argv = [program.url.path]
        if query {
            argv.append("--no-optional-locks")
        }
        argv.append(contentsOf: arguments)
        if !clientValues.isEmpty {
            argv.append("--end-of-options")
            argv.append(contentsOf: clientValues)
        }
        if !paths.isEmpty {
            argv.append("--")
            argv.append(contentsOf: paths)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["SSH_ASKPASS"] = "/usr/bin/false"
        environment["GIT_PAGER"] = "cat"
        environment["LC_ALL"] = "C"
        environment["PWD"] = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if let indexFile {
            environment["GIT_INDEX_FILE"] = indexFile.path
        } else {
            environment.removeValue(forKey: "GIT_INDEX_FILE")
        }
        for (key, value) in extra {
            environment[key] = value
        }

        return spawn(argv: argv, environment: environment, folder: folder)
    }

    private func spawn(argv: [String], environment: [String: String], folder: URL)
        -> Result<GitOutput, GitFailure> {
        var outPipe: [Int32] = [0, 0]
        var errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0, pipe(&errPipe) == 0 else {
            return .failure(.unavailable("could not create a pipe to git: \(errnoText())"))
        }

        var fileActions: posix_spawn_file_actions_t?
        let actionsResult = posix_spawn_file_actions_init(&fileActions)
        guard actionsResult == 0, fileActions != nil else {
            close(outPipe[0])
            close(outPipe[1])
            close(errPipe[0])
            close(errPipe[1])
            return .failure(.unavailable(
                "could not prepare to start git: \(spawnError(actionsResult))"))
        }

        var attributes: posix_spawnattr_t?
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0, attributes != nil else {
            posix_spawn_file_actions_destroy(&fileActions)
            close(outPipe[0])
            close(outPipe[1])
            close(errPipe[0])
            close(errPipe[1])
            return .failure(.unavailable(
                "could not prepare to start git: \(spawnError(attributesResult))"))
        }

        var argvPointers: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var envPointers: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argvPointers where pointer != nil { free(pointer) }
            for pointer in envPointers where pointer != nil { free(pointer) }
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_adddup2(&fileActions, outPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, outPipe[1])
        posix_spawn_file_actions_addclose(&fileActions, errPipe[1])
        guard let chdir = GitRunner.addChangeDirectory else {
            close(outPipe[0])
            close(outPipe[1])
            close(errPipe[0])
            close(errPipe[1])
            return .failure(.unavailable(
                "this Mac cannot set the working folder of a child process"))
        }
        guard chdir(&fileActions, folder.path) == 0 else {
            close(outPipe[0])
            close(outPipe[1])
            close(errPipe[0])
            close(errPipe[1])
            return .failure(.unavailable(
                "could not set the working folder to \(folder.path): \(errnoText())"))
        }

        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var pid: pid_t = 0
        let spawnCode = posix_spawn(&pid, program.url.path, &fileActions, &attributes,
                                    &argvPointers, &envPointers)
        close(outPipe[1])
        close(errPipe[1])
        guard spawnCode == 0 else {
            close(outPipe[0])
            close(errPipe[0])
            return .failure(.unavailable(
                "could not start \(program.url.path): \(spawnError(spawnCode))"))
        }

        let box = OutputBox()
        let readers = DispatchGroup()
        let outHandle = FileHandle(fileDescriptor: outPipe[0], closeOnDealloc: true)
        let errHandle = FileHandle(fileDescriptor: errPipe[0], closeOnDealloc: true)
        readers.enter()
        DispatchQueue.global().async {
            box.setOutput(outHandle.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global().async {
            let data = errHandle.readDataToEndOfFile()
            box.setError(String(decoding: data, as: UTF8.self))
            readers.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        var finished = false
        while Date() < deadline {
            let reaped = waitpid(pid, &status, WNOHANG)
            if reaped == pid {
                finished = true
                break
            }
            if reaped == -1 && errno != EINTR {
                finished = true
                break
            }
            usleep(20_000)
        }

        if !finished {
            kill(-pid, SIGKILL)
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            _ = readers.wait(timeout: .now() + 5)
            return .failure(.timedOut(seconds: timeout))
        }

        _ = readers.wait(timeout: .now() + 5)
        let exitCode = GitRunner.exitCode(from: status)
        let (output, error) = box.values()

        if exitCode != 0 {
            let trimmedError = error.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedOutput = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message: String
            if !trimmedError.isEmpty {
                message = trimmedError
            } else if !trimmedOutput.isEmpty {
                message = trimmedOutput
            } else {
                message = "git exited with \(exitCode)"
            }
            return .failure(.failed(exitCode: exitCode, message: message))
        }

        return .success(GitOutput(exitCode: exitCode, standardOutput: output, standardError: error))
    }

    private static func exitCode(from status: Int32) -> Int32 {
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        }
        return status & 0x7f
    }

    private func errnoText() -> String {
        String(cString: strerror(errno))
    }

    private func spawnError(_ code: Int32) -> String {
        code == 0 ? "no error" : String(cString: strerror(code))
    }
}

/// The half of the revision gate that must run a process, so it lives beside the
/// only type that starts one; the refusal names and the error value stay in
/// `GitRevision`.
extension GitRevision {
    static func accept(_ value: String, folder: URL, runner: GitRunner)
        -> Result<String, GitOperationError> {
        if value == "HEAD" {
            return .success(value)
        }
        guard isCommitId(value) || CheckpointRefs.isCheckpointRef(value) else {
            return .failure(refusal(value))
        }
        switch runner.run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(value)^{commit}"],
                          in: folder, query: true) {
        case .success:
            return .success(value)
        case .failure:
            return .failure(refusal(value))
        }
    }

    private static func refusal(_ value: String) -> GitOperationError {
        GitOperationError(
            code: "invalid_params",
            message: "the revision \"\(value)\" is not HEAD, a commit id or a checkpoint reference of this project")
    }
}

/// The two pipe readers run beside the process, so their results are collected
/// behind a lock and read after both have finished.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = ""

    func setOutput(_ data: Data) {
        lock.lock()
        output = data
        lock.unlock()
    }

    func setError(_ text: String) {
        lock.lock()
        error = text
        lock.unlock()
    }

    func values() -> (Data, String) {
        lock.lock()
        defer { lock.unlock() }
        return (output, error)
    }
}
