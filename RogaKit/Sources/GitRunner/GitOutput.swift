import Foundation

/// The output of a git command as an async sequence of chunks of bytes, in
/// the order git wrote them.
///
/// Iterating starts git, and each iteration runs the command again. Chunks
/// arrive as git writes them, and git waits when the consumer falls behind,
/// so even a very long output never piles up in memory. When git exits with a
/// status the command doesn't count as success, the last call to `next()`
/// throws `GitError.failed`. Leaving the loop early, or cancelling the task
/// that's iterating, stops git.
public struct GitOutput: AsyncSequence, Sendable {
    public typealias Element = [UInt8]

    let git: Git
    let command: GitCommand
    let input: [UInt8]?

    public func makeAsyncIterator() -> Iterator {
        Iterator(git: git, command: command, input: input)
    }

    /// Splits the output into records that end with `separator`, such as the
    /// NUL that ends each record of `-z` output.
    public func records(separatedBy separator: UInt8) -> GitRecords<GitOutput> {
        GitRecords(base: self, separator: separator)
    }

    public final class Iterator: AsyncIteratorProtocol {
        private let git: Git
        private let command: GitCommand
        private let input: [UInt8]?
        private var running: RunningGit?
        private var finished = false

        init(git: Git, command: GitCommand, input: [UInt8]?) {
            self.git = git
            self.command = command
            self.input = input
        }

        deinit {
            if !finished { running?.stop() }
        }

        public func next() async throws -> [UInt8]? {
            guard !finished else { return nil }
            let running: RunningGit
            if let started = self.running {
                running = started
            } else {
                do {
                    try Task.checkCancellation()
                    running = try git.start(command, withInput: input != nil)
                } catch {
                    finished = true
                    throw error
                }
                self.running = running
                if let input, let writer = running.process.input {
                    // Write while reading, so that neither side waits for the other.
                    writer.submit(input)
                    writer.close()
                }
            }
            do {
                let chunk = try await withTaskCancellationHandler {
                    try await running.process.output.next()
                } onCancel: {
                    running.stop()
                }
                if let chunk { return chunk }
                finished = true
                _ = try await running.finish()
                return nil
            } catch {
                finished = true
                running.stop()
                throw error
            }
        }
    }
}

/// Splits chunks of bytes into records that end with a separator byte. A last
/// record without a separator is returned too, unless it's empty.
///
/// A record that arrives within one chunk is a slice of that chunk and isn't
/// copied. A record split across chunks is put back together first.
public struct GitRecords<Base: AsyncSequence & Sendable>: AsyncSequence, Sendable where Base.Element == [UInt8] {
    public typealias Element = ArraySlice<UInt8>

    let base: Base
    let separator: UInt8

    public init(base: Base, separator: UInt8) {
        self.base = base
        self.separator = separator
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), separator: separator)
    }

    public struct Iterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let separator: UInt8
        var chunk: [UInt8] = []
        var position = 0
        var pending: [UInt8] = []
        var baseEnded = false

        public mutating func next() async throws -> ArraySlice<UInt8>? {
            while true {
                if position < chunk.count {
                    let start = position
                    let end = chunk.withUnsafeBufferPointer { bytes -> Int? in
                        guard let base = bytes.baseAddress,
                              let hit = memchr(base + start, Int32(separator), bytes.count - start)
                        else { return nil }
                        return UnsafeRawPointer(hit) - UnsafeRawPointer(base)
                    }
                    if let end {
                        position = end + 1
                        if pending.isEmpty {
                            return chunk[start..<end]
                        }
                        pending.append(contentsOf: chunk[start..<end])
                        defer { pending = [] }
                        return pending[...]
                    }
                    pending.append(contentsOf: chunk[start...])
                    position = chunk.count
                }
                if baseEnded { return nil }
                guard let next = try await base.next(isolation: #isolation) else {
                    baseEnded = true
                    chunk = []
                    position = 0
                    if pending.isEmpty { return nil }
                    defer { pending = [] }
                    return pending[...]
                }
                chunk = next
                position = 0
            }
        }
    }
}
