import Darwin
import Foundation
import Synchronization
@testable import AgentHooks

/// A new, empty temporary folder at its real path. Its name is short,
/// because a socket's whole path has to fit in 103 bytes.
func makeTemporaryFolder() throws -> URL {
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let folder = temporary.appending(path: "rh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Waits until `condition` is true, for up to `timeout`.
func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

func date(_ seconds: Double) -> Date {
    Date(timeIntervalSince1970: seconds)
}

/// Everything a listener yields, collected by one task for the listener's
/// whole life, since a stream has one reader.
final class Received: Sendable {
    private let events = Mutex<[HookEvent]>([])

    init(from listener: HookListener) {
        Task { [self] in
            for await event in listener.events {
                self.events.withLock { $0.append(event) }
            }
        }
    }

    var all: [HookEvent] {
        events.withLock { $0 }
    }
}

/// A pipe that a thread of its own fills with `bytes` and then closes, the
/// way an agent writes a hook's input.
final class Feeder: Sendable {
    let readEnd: Int32
    private let outcome = Mutex<Bool?>(nil)

    init(_ bytes: [UInt8]) {
        var ends: [Int32] = [0, 0]
        precondition(pipe(&ends) == 0)
        readEnd = ends[0]
        let writeEnd = ends[1]
        // A reader that stops early should make the write fail, not stop the
        // tests with SIGPIPE.
        _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
        Thread { [self] in
            var written = 0
            var failed = false
            while written < bytes.count {
                let count = bytes.withUnsafeBytes { buffer in
                    write(writeEnd, buffer.baseAddress.map { $0 + written }, buffer.count - written)
                }
                if count > 0 {
                    written += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    failed = true
                    break
                }
            }
            close(writeEnd)
            self.outcome.withLock { $0 = !failed }
        }.start()
    }

    convenience init(_ text: String) {
        self.init(Array(text.utf8))
    }

    deinit {
        close(readEnd)
    }

    /// Waits for the writer, and says whether it wrote everything.
    func wroteEverything() async -> Bool {
        _ = await eventually { outcome.withLock { $0 != nil } }
        return outcome.withLock { $0 } ?? false
    }
}

/// Connects to a socket the way the helper does, but leaves writing to the
/// test.
func connectToSocket(at path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    var on: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let result = HookSocket.withAddress(of: path) { connect(descriptor, $0, $1) }
    guard result == 0 else {
        close(descriptor)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
}

/// Writes all of `bytes`, and says whether it could.
@discardableResult
func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
    var written = 0
    while written < bytes.count {
        let count = bytes.withUnsafeBytes { buffer in
            write(descriptor, buffer.baseAddress.map { $0 + written }, buffer.count - written)
        }
        guard count > 0 else { return false }
        written += count
    }
    return true
}

/// A socket file that nothing listens on, like one left by a copy of Roga
/// that crashed.
func makeAbandonedSocket(at path: String) {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    _ = HookSocket.withAddress(of: path) { bind(descriptor, $0, $1) }
    close(descriptor)
}
