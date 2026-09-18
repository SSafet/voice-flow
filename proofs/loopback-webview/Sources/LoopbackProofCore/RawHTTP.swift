import Darwin
import Foundation

/// A hand-written HTTP/1.1 client. It exists because URLSession refuses to send a
/// `Host` header that disagrees with the address it dialled, and that disagreement
/// is one of the things this proof has to try.
public enum RawHTTP {
    public struct Reply: Sendable {
        public let status: Int
        public let raw: String
    }

    public enum Failure: Error, CustomStringConvertible {
        case cannotConnect(String)
        case noReply
        public var description: String {
            switch self {
            case .cannotConnect(let why): return "cannot connect: \(why)"
            case .noReply: return "no reply"
            }
        }
    }

    /// `address` is a numeric loopback address: "127.0.0.1" or "::1".
    public static func send(address: String, port: Int, request: String, timeoutSeconds: Int = 3) throws -> Reply {
        let isIPv6 = address.contains(":")
        let fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.cannotConnect("socket() failed") }
        defer { close(fd) }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let connected: Int32
        if isIPv6 {
            var addr = sockaddr_in6()
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else {
                throw Failure.cannotConnect("inet_pton failed for \(address)")
            }
            connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else {
                throw Failure.cannotConnect("inet_pton failed for \(address)")
            }
            connected = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard connected == 0 else {
            throw Failure.cannotConnect("connect() to \(address):\(port) failed (\(errnoText()))")
        }

        let outgoing = Array(request.utf8)
        var sent = 0
        while sent < outgoing.count {
            let n = outgoing.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), outgoing.count - sent) }
            guard n > 0 else { throw Failure.noReply }
            sent += n
        }

        var incoming = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            incoming.append(contentsOf: buffer[0..<n])
            if incoming.count > 64 * 1024 { break }
            if let text = String(bytes: incoming, encoding: .utf8), text.contains("\r\n\r\n") { break }
        }
        guard let raw = String(bytes: incoming, encoding: .utf8), !raw.isEmpty else { throw Failure.noReply }
        let firstLine = raw.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return Reply(status: status, raw: raw)
    }

    /// True when something accepts a connection on that address and port.
    public static func accepts(address: String, port: Int) -> Bool {
        (try? send(address: address, port: port, request: "GET / HTTP/1.1\r\nHost: localhost:\(port)\r\nConnection: close\r\n\r\n")) != nil
    }

    /// The system's word for the last failure, so a failed check names the reason
    /// rather than only the address it could not reach.
    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
