import Foundation
import Darwin

/// The controller owns the write end. Its death closes the pipe without a signal.
enum WatcherParentLifetime {
    static func watch(fd: Int32, onEOF: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var byte: UInt8 = 0
            while true {
                let count = read(fd, &byte, 1)
                if count > 0 { continue }
                if count < 0 && errno == EINTR { continue }
                DispatchQueue.main.async { onEOF() }
                return
            }
        }
    }
}
