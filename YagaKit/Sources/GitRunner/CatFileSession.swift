import Foundation
import GitCore
import Synchronization

/// A long-running `git cat-file --batch-command` process that reads objects
/// on request, such as the commits for the rows the commit list is about to
/// draw. Reading a window of 100 commits this way took 1.4 ms in the
/// prototype, against about 9 ms just to start a new git.
///
/// Requests can come from several tasks at once. Each one is written to git
/// as a single batch, and git answers batches in the order they arrive, so
/// every task gets its own replies. Cancelling a task that's waiting for a
/// reply returns at once, and the replies git sends later are dropped.
public final class CatFileSession: Sendable {
    /// An object and its contents.
    public struct Object: Sendable, Hashable {
        public var id: ObjectID
        public var type: ObjectType
        public var contents: [UInt8]
    }

    /// An object's type and size, without its contents.
    public struct Info: Sendable, Hashable {
        public var id: ObjectID
        public var type: ObjectType
        public var size: Int
    }

    private let core: Core

    /// Starts `git cat-file` in `directory`, which can be any worktree of the
    /// repository or its git directory.
    public init(git: Git, directory: String) throws {
        let command = GitCommand("cat-file", "--batch-command", "--buffer", in: directory)
        core = Core(running: try git.start(command, withInput: true))
        core.startReading()
    }

    deinit {
        core.close()
    }

    /// Reads objects by name. A name is anything git accepts for an object,
    /// such as a full ID, `HEAD`, or `HEAD:path/to/file`. The result has one
    /// entry for each name, which is nil when there's no such object or the
    /// name is ambiguous.
    public func objects(_ names: [String]) async throws -> [Object?] {
        try await core.request(names, wantsContents: true).map { reply in
            if case .object(let object) = reply { object } else { nil }
        }
    }

    /// Reads the type and size of objects by name, like `objects(_:)` but
    /// without their contents.
    public func info(_ names: [String]) async throws -> [Info?] {
        try await core.request(names, wantsContents: false).map { reply in
            if case .info(let info) = reply { info } else { nil }
        }
    }

    /// Answers the requests already made, then ends the process. Later
    /// requests throw `GitError.sessionClosed`.
    public func close() {
        core.close()
    }
}

extension CatFileSession {
    enum Reply: Sendable {
        case missing
        case info(Info)
        case object(Object)
    }

    /// The parts of a session that the task reading git's replies keeps alive,
    /// so that dropping the session itself closes it.
    final class Core: Sendable {
        let running: RunningGit
        private let state = Mutex(State())

        private struct State {
            var batches: [Batch] = []
            var nextID = 0
            var closed = false
            var failure: GitError?
        }

        private struct Batch {
            let id: Int
            let wantsContents: Bool
            let count: Int
            var replies: [Reply] = []
            var continuation: CheckedContinuation<[Reply], any Error>?
        }

        init(running: RunningGit) {
            self.running = running
        }

        func startReading() {
            Task { await readReplies() }
        }

        func close() {
            let shouldClose = state.withLock { state in
                defer { state.closed = true }
                return !state.closed
            }
            if shouldClose { running.process.input?.close() }
        }

        func request(_ names: [String], wantsContents: Bool) async throws -> [Reply] {
            guard !names.isEmpty else { return [] }
            for name in names where name.isEmpty || name.contains(where: \.isNewline) {
                throw GitError.invalidObjectName(name)
            }
            let verb = wantsContents ? "contents " : "info "
            var request = ""
            for name in names {
                request += verb
                request += name
                request += "\n"
            }
            request += "flush\n"
            let bytes = Array(request.utf8)

            try Task.checkCancellation()
            let id = state.withLock { state in
                defer { state.nextID += 1 }
                return state.nextID
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let failure = state.withLock { state -> GitError? in
                        if let failure = state.failure { return failure }
                        if state.closed { return .sessionClosed(running.command) }
                        state.batches.append(Batch(
                            id: id,
                            wantsContents: wantsContents,
                            count: names.count,
                            continuation: continuation
                        ))
                        // Submitting under the lock keeps the order of the
                        // batches the same as the order git receives them in.
                        // A failed write needs no handling here: it means git
                        // has exited, and the reader fails every batch.
                        running.process.input?.submit(bytes)
                        return nil
                    }
                    if let failure { continuation.resume(throwing: failure) }
                }
            } onCancel: {
                let continuation = state.withLock { state -> CheckedContinuation<[Reply], any Error>? in
                    guard let index = state.batches.firstIndex(where: { $0.id == id }) else { return nil }
                    defer { state.batches[index].continuation = nil }
                    return state.batches[index].continuation
                }
                continuation?.resume(throwing: CancellationError())
            }
        }

        /// Reads replies until git exits, and hands each batch its replies.
        private func readReplies() async {
            var buffer: [UInt8] = []
            var position = 0
            var failure: GitError?

            reading: while true {
                do {
                    guard let chunk = try await running.process.output.next() else { break reading }
                    buffer.append(contentsOf: chunk)
                } catch {
                    break reading
                }
                do {
                    while let (reply, end) = try parseReply(in: buffer, from: position) {
                        position = end
                        try deliver(reply)
                    }
                } catch {
                    failure = error
                    running.stop()
                    break reading
                }
                if position > 0 {
                    buffer.removeFirst(position)
                    position = 0
                }
            }

            if failure == nil {
                do {
                    _ = try await running.finish()
                    failure = .sessionClosed(running.command)
                } catch let error as GitError {
                    failure = error
                } catch {
                    failure = .sessionClosed(running.command)
                }
            }
            let batches = state.withLock { state in
                state.failure = failure
                state.closed = true
                defer { state.batches = [] }
                return state.batches
            }
            for batch in batches {
                batch.continuation?.resume(throwing: failure ?? .sessionClosed(running.command))
            }
        }

        /// Parses the reply that starts at `position`, if all of it has
        /// arrived, and returns it with the position after it.
        private func parseReply(in buffer: [UInt8], from position: Int) throws(GitError) -> (Reply, Int)? {
            guard position < buffer.count else { return nil }
            guard let newline = buffer[position...].firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            let header = String(decoding: buffer[position..<newline], as: UTF8.self)
            let afterHeader = newline + 1

            if header.hasSuffix(" missing") || header.hasSuffix(" ambiguous") {
                return (.missing, afterHeader)
            }
            let fields = header.split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let id = ObjectID(hex: fields[0]),
                  let type = ObjectType(rawValue: String(fields[1])),
                  let size = Int(fields[2]), size >= 0
            else { throw .unexpectedReply(running.command, header) }

            let wantsContents = try state.withLock { state throws(GitError) -> Bool in
                guard let batch = state.batches.first else {
                    throw .unexpectedReply(running.command, header)
                }
                return batch.wantsContents
            }
            guard wantsContents else {
                return (.info(Info(id: id, type: type, size: size)), afterHeader)
            }
            // The contents are followed by a newline.
            let end = afterHeader + size + 1
            guard buffer.count >= end else { return nil }
            guard buffer[end - 1] == UInt8(ascii: "\n") else {
                throw .unexpectedReply(running.command, header)
            }
            let contents = Array(buffer[afterHeader..<(end - 1)])
            return (.object(Object(id: id, type: type, contents: contents)), end)
        }

        private func deliver(_ reply: Reply) throws(GitError) {
            let finished = try state.withLock { state throws(GitError) -> Batch? in
                guard !state.batches.isEmpty else {
                    throw .unexpectedReply(running.command, "a reply nobody asked for")
                }
                state.batches[0].replies.append(reply)
                guard state.batches[0].replies.count == state.batches[0].count else { return nil }
                return state.batches.removeFirst()
            }
            if let finished {
                finished.continuation?.resume(returning: finished.replies)
            }
        }
    }
}
