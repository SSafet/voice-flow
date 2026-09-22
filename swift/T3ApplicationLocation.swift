import Foundation
import Darwin

/// Local browser origin and WebKit identity must remain stable across child and
/// app restarts; the upstream environment still owns all canonical data.
struct T3ApplicationLocation: Codable {
    let port: UInt16
    let browserStore: UUID
    static func open(root: URL) throws -> Self {
        let fm = FileManager.default
        var ancestor = root.standardizedFileURL
        while !fm.fileExists(atPath: ancestor.path), ancestor.path != "/" { ancestor.deleteLastPathComponent() }
        guard ancestor.path == ancestor.resolvingSymlinksInPath().path else { throw T3EnvironmentProcessError.invalidHome }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { throw T3EnvironmentProcessError.invalidHome }
        let file = root.appendingPathComponent("native-location.json")
        if fm.fileExists(atPath: file.path) {
            guard file.standardizedFileURL.path == file.resolvingSymlinksInPath().path else { throw T3EnvironmentProcessError.invalidHome }
            let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw T3EnvironmentProcessError.invalidHome }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var stat = Darwin.stat()
            guard fstat(descriptor, &stat) == 0, stat.st_mode & S_IFMT == S_IFREG else { throw T3EnvironmentProcessError.invalidHome }
            let bytes = try handle.read(upToCount: 4097) ?? Data()
            guard bytes.count <= 4096 else { throw T3EnvironmentProcessError.invalidHome }
            let saved = try JSONDecoder().decode(Self.self, from: bytes)
            guard saved.port >= 1024, ![8792, 8793].contains(saved.port) else { throw T3EnvironmentProcessError.invalidHome }
            return saved
        }
        // Ask the OS for a free loopback port once. Never silently switch origin
        // if it is occupied later; the upstream launcher reports the conflict.
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw T3EnvironmentProcessError.invalidHome }
        defer { close(socketFD) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &size) } }
        guard bound == 0, read == 0 else { throw T3EnvironmentProcessError.invalidHome }
        let value = Self(port: UInt16(bigEndian: address.sin_port), browserStore: UUID())
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if descriptor < 0, errno == EEXIST { return try open(root: root) }
        guard descriptor >= 0 else { throw T3EnvironmentProcessError.invalidHome }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(value)); try handle.synchronize()
        return value
    }
}
