import Foundation
import Synchronization

/// A record of the commands Roga ran, git's and other programs': their
/// arguments, where they ran, how long they took and how they ended. It keeps
/// the most recent commands, up to its capacity.
///
/// This is how Roga keeps the vision's promise to show what Git is doing. A
/// view of the log comes later.
public final class CommandLog: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public let id: Int
        /// The program that ran: `git` for git's commands, or the absolute path
        /// of any other program.
        public let program: String
        /// The arguments the program received, after its name.
        public let arguments: [String]
        public let directory: String?
        public let started: Date
        /// How long the command ran, or nil while it's running.
        public internal(set) var duration: Duration?
        public internal(set) var outcome: Outcome
    }

    public enum Outcome: Sendable, Hashable {
        case running
        case finished(ExitStatus)
        case couldNotStart(String)
    }

    public let capacity: Int

    private let state = Mutex(State())

    private struct State {
        var entries: [Entry] = []
        var startTimes: [Int: ContinuousClock.Instant] = [:]
        var nextID = 1
    }

    public init(capacity: Int = 1000) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// The recorded commands, oldest first.
    public var entries: [Entry] {
        state.withLock { $0.entries }
    }

    func begin(_ command: GitCommand) -> Int {
        begin(program: "git", arguments: command.fullArguments, directory: command.directory)
    }

    func begin(program: String, arguments: [String], directory: String?) -> Int {
        let started = Date()
        let clock = ContinuousClock.now
        return state.withLock { state in
            let id = state.nextID
            state.nextID += 1
            state.entries.append(Entry(
                id: id,
                program: program,
                arguments: arguments,
                directory: directory,
                started: started,
                duration: nil,
                outcome: .running
            ))
            state.startTimes[id] = clock
            if state.entries.count > capacity {
                let dropped = state.entries.prefix(state.entries.count - capacity)
                for entry in dropped { state.startTimes[entry.id] = nil }
                state.entries.removeFirst(dropped.count)
            }
            return id
        }
    }

    func finish(_ id: Int, _ outcome: Outcome) {
        let now = ContinuousClock.now
        state.withLock { state in
            guard let first = state.entries.first, id >= first.id else { return }
            let index = id - first.id
            guard index < state.entries.count else { return }
            if let start = state.startTimes.removeValue(forKey: id) {
                state.entries[index].duration = now - start
            }
            state.entries[index].outcome = outcome
        }
    }
}
