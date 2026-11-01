import Darwin
import Dispatch
import Foundation
import Synchronization

/// Reads one end of a pipe with `DispatchIO`, a chunk at a time as the
/// consumer asks for it.
///
/// Reading never blocks a thread. At most one read of `readLength` bytes is
/// outstanding at a time, so when the consumer falls behind, the pipe fills up
/// and the writer waits, instead of the output piling up in memory.
final class PipeReader: Sendable {
    static let readLength = 256 * 1024

    private let channel: DispatchIO
    private let queue: DispatchQueue
    private let state = Mutex(State())

    private struct State {
        var buffer: [UInt8] = []
        var reading = false
        var bytesThisRead = 0
        var ended = false
        var errorNumber: Int32 = 0
        var waiter: CheckedContinuation<[UInt8]?, any Error>?
    }

    /// Takes ownership of `fileDescriptor` and closes it when the reader is
    /// closed.
    init(fileDescriptor: Int32, queue: DispatchQueue) {
        self.queue = queue
        channel = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in
            Darwin.close(fileDescriptor)
        }
        // Deliver bytes as soon as any arrive, rather than waiting for a full read.
        channel.setLimit(lowWater: 1)
    }

    deinit {
        channel.close(flags: .stop)
    }

    /// Returns the bytes that have arrived since the last call, waiting for
    /// some if there are none, or nil once the writer has closed the pipe.
    /// Only one task may wait at a time.
    func next() async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { continuation in
            let (result, startRead) = state.withLock { state -> (Result<[UInt8]?, any Error>?, Bool) in
                if !state.buffer.isEmpty {
                    let bytes = state.buffer
                    state.buffer = []
                    // Start the next read now, so the writer can keep going
                    // while the consumer handles these bytes.
                    return (.success(bytes), Self.claimRead(&state))
                }
                if state.ended {
                    return (Self.endResult(state), false)
                }
                precondition(state.waiter == nil, "Only one task can read a pipe at a time")
                state.waiter = continuation
                return (nil, Self.claimRead(&state))
            }
            if startRead { self.startRead() }
            if let result { continuation.resume(with: result) }
        }
    }

    /// Stops reading. A task waiting in `next()` gets nil, and the file
    /// descriptor is closed, so the writer gets `EPIPE` if it writes again.
    func close() {
        channel.close(flags: .stop)
    }

    private func startRead() {
        channel.read(offset: 0, length: Self.readLength, queue: queue) { [self] done, data, error in
            let bytes = data?.bytes ?? []
            let (waiter, result, startRead) = state.withLock { state in
                if state.buffer.isEmpty {
                    state.buffer = bytes
                } else {
                    state.buffer.append(contentsOf: bytes)
                }
                state.bytesThisRead += bytes.count
                if done {
                    state.reading = false
                    // A read that stops short of its length has reached the end.
                    if error == ECANCELED || (error == 0 && state.bytesThisRead < Self.readLength) {
                        state.ended = true
                    } else if error != 0 {
                        state.ended = true
                        state.errorNumber = error
                    }
                    state.bytesThisRead = 0
                }
                return Self.serveWaiter(&state)
            }
            if startRead { self.startRead() }
            if let waiter, let result { waiter.resume(with: result) }
        }
    }

    /// Hands buffered bytes, or the end of the pipe, to a waiting task, and
    /// says whether a new read needs to start.
    private static func serveWaiter(
        _ state: inout State
    ) -> (CheckedContinuation<[UInt8]?, any Error>?, Result<[UInt8]?, any Error>?, Bool) {
        guard let waiter = state.waiter else { return (nil, nil, false) }
        if !state.buffer.isEmpty {
            let bytes = state.buffer
            state.buffer = []
            state.waiter = nil
            return (waiter, .success(bytes), claimRead(&state))
        }
        if state.ended {
            state.waiter = nil
            return (waiter, endResult(state), false)
        }
        // The read finished exactly at its length and everything it read has
        // already been handed out, so read again for the waiting task.
        return (nil, nil, claimRead(&state))
    }

    private static func claimRead(_ state: inout State) -> Bool {
        guard !state.reading, !state.ended else { return false }
        state.reading = true
        return true
    }

    private static func endResult(_ state: State) -> Result<[UInt8]?, any Error> {
        state.errorNumber == 0
            ? .success(nil)
            : .failure(POSIXError(POSIXErrorCode(rawValue: state.errorNumber) ?? .EIO))
    }
}

/// Writes to one end of a pipe with `DispatchIO`. Writes happen in the order
/// they're submitted.
final class PipeWriter: Sendable {
    private let channel: DispatchIO
    private let queue: DispatchQueue

    /// Takes ownership of `fileDescriptor` and closes it once the writer is
    /// closed and its writes have finished.
    init(fileDescriptor: Int32, queue: DispatchQueue) {
        // Writing to a pipe whose reader has gone away should fail with EPIPE,
        // not raise SIGPIPE and stop yaga.
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
        self.queue = queue
        channel = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in
            Darwin.close(fileDescriptor)
        }
    }

    deinit {
        channel.close()
    }

    /// Queues `bytes` to be written and returns at once. `completion` gets 0
    /// once they're all written, or the error that stopped them.
    func submit(_ bytes: [UInt8], completion: @escaping @Sendable (Int32) -> Void = { _ in }) {
        guard !bytes.isEmpty else {
            completion(0)
            return
        }
        let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: data, queue: queue) { done, _, error in
            if done { completion(error) }
        }
    }

    /// Writes `bytes` and waits until they're written.
    func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            submit(bytes) { error in
                if error == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
                }
            }
        }
    }

    /// Closes the pipe once the writes already submitted have finished, so
    /// the reader sees the end of its input.
    func close() {
        channel.close()
    }
}

/// Reads everything from a pipe and keeps the end of it, up to a limit. yaga
/// uses it for standard error, which has to be drained all the time so that a
/// child never blocks on it, and whose last lines say what went wrong.
final class PipeCollector: Sendable {
    let limit: Int

    private let channel: DispatchIO
    private let state = Mutex(State())

    private struct State {
        var bytes: [UInt8] = []
        var ended = false
        var waiters: [CheckedContinuation<[UInt8], Never>] = []
    }

    init(fileDescriptor: Int32, queue: DispatchQueue, limit: Int = 64 * 1024) {
        self.limit = limit
        channel = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in
            Darwin.close(fileDescriptor)
        }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { [self] done, data, _ in
            let waiters = state.withLock { state -> [CheckedContinuation<[UInt8], Never>] in
                if let data, !data.isEmpty {
                    state.bytes.append(contentsOf: data.bytes)
                    if state.bytes.count > limit {
                        state.bytes.removeFirst(state.bytes.count - limit)
                    }
                }
                guard done else { return [] }
                state.ended = true
                defer { state.waiters = [] }
                return state.waiters
            }
            if done { channel.close() }
            let bytes = state.withLock { $0.bytes }
            for waiter in waiters { waiter.resume(returning: bytes) }
        }
    }

    /// Waits until the writer closes the pipe and returns the end of what it
    /// wrote.
    func collected() async -> [UInt8] {
        await withCheckedContinuation { continuation in
            let bytes = state.withLock { state -> [UInt8]? in
                if state.ended { return state.bytes }
                state.waiters.append(continuation)
                return nil
            }
            if let bytes { continuation.resume(returning: bytes) }
        }
    }

    /// Stops reading and closes the pipe.
    func close() {
        channel.close(flags: .stop)
    }
}

extension DispatchData {
    var bytes: [UInt8] {
        // With a capacity of 0, the array initializer writes to the storage
        // that every empty array shares, which is a data race when pipes on
        // several queues reach their end at once.
        guard !isEmpty else { return [] }
        return [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            initialized = copyBytes(to: buffer)
        }
    }
}
