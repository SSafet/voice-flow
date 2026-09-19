import Foundation

/// The tiny check harness every suite in tests/device_identity uses. Plain
/// `main.swift`-style output, like the rest of the VoiceFlow test tree: one
/// `not ok - <reason>` line per failure and a non-zero exit, so the harness
/// reports a real failure and never a warning.
final class Checks {
    private(set) var passed = 0
    private(set) var failures: [String] = []

    func check(_ condition: @autoclosure () throws -> Bool, _ what: String) {
        do {
            if try condition() {
                passed += 1
            } else {
                failures.append(what)
            }
        } catch {
            failures.append("\(what): threw \(error)")
        }
    }

    func equal<T: Equatable>(_ got: T, _ expected: T, _ what: String) {
        check(got == expected, "\(what): \(got) is not \(expected)")
    }

    func notEqual<T: Equatable>(_ got: T, _ unexpected: T, _ what: String) {
        check(got != unexpected, "\(what): \(got) is the value it must not be")
    }

    func finish(_ label: String) -> Never {
        if failures.isEmpty {
            print("\(label): \(passed) checks passed")
            exit(0)
        }
        for failure in failures {
            FileHandle.standardError.write(Data("not ok - \(failure)\n".utf8))
        }
        FileHandle.standardError.write(
            Data("\(label): \(failures.count) of \(passed + failures.count) checks failed\n".utf8))
        exit(1)
    }
}
