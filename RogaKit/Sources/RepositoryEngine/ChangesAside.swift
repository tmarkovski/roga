import Foundation
import GitCore
import GitRunner

/// Uncommitted changes that Roga set aside in a stash, because a pull or going to a
/// commit would otherwise have refused to overwrite them, and that go back once the
/// move is done (decision 58).
public struct ChangesAside: Sendable, Hashable {
    /// What moves `HEAD`, which decides which changes are in its way, and how to
    /// go back.
    public enum Move: Sendable, Hashable {
        /// A pull from the upstream, by its full name. A rebase refuses to start
        /// with any uncommitted change, whereas a merge only refuses to overwrite
        /// the files its commits change.
        case pull(upstream: String, rebases: Bool)
        /// Moving the branch to a commit with `git reset --keep`.
        case reset(to: ObjectID)
        /// Detaching `HEAD` at a commit with `git switch --detach`.
        case detach(at: ObjectID)
    }

    /// How putting the changes back went.
    public enum PutBack: Sendable, Hashable {
        /// They're back as they were, including what was staged, and the stash is gone.
        case back
        /// They're back, but these files have conflicts, and the stash stays. The
        /// files that came back cleanly are staged only if they were before.
        case conflicted(files: [String])
        /// git wouldn't put them back, so they're all still in the stash. This is
        /// what ran and what git said.
        case stillAside(ran: [String], said: String)
    }

    /// The stash can't be found to put back, because something else has popped or
    /// dropped it.
    public struct Missing: Error, Sendable, Hashable, CustomStringConvertible {
        public var stash: ObjectID

        public var description: String {
            "The stash Roga made, \(stash.hex.prefix(8)), isn't in the list of stashes any more, so Roga can't put it back."
        }
    }

    /// The stash's commit.
    public var stash: ObjectID
    /// What they were set aside for.
    public var move: Move
    /// Where `HEAD` was before the move, which is where the changes fit.
    public var head: ObjectID
    /// The full name of the branch `HEAD` was on, or nil when it was detached.
    public var branch: String?
    /// The stash's message, as the list of stashes shows it.
    public var message: String

    public init(stash: ObjectID, move: Move, head: ObjectID, branch: String? = nil, message: String) {
        self.stash = stash
        self.move = move
        self.head = head
        self.branch = branch
        self.message = message
    }

    /// What sets them aside, by its arguments after `git`.
    public static func arguments(message: String) -> [String] {
        ["stash", "push", "--message", message]
    }

    /// What puts them back, when the stash is the newest one, as it nearly always is.
    public static let putBackArguments = ["stash", "pop", "--index"]

    /// What goes back to before the move, ahead of putting the changes back:
    /// aborting a merge or a rebase the pull stopped partway through, then taking
    /// `HEAD` and the files back to where they were. Everything uncommitted from
    /// before is in the stash, so all of this can be thrown away.
    public func undoArguments(stopped: StoppedWork?) -> [[String]] {
        var commands: [[String]] = stopped.map { [$0.abortArguments] } ?? []
        switch move {
        case .pull, .reset:
            commands.append(["reset", "--hard", head.hex])
        case .detach:
            if let branch {
                commands.append(["switch", "--discard-changes", Ref.shortName(branch)])
            } else {
                commands.append(["switch", "--discard-changes", "--detach", head.hex])
            }
        }
        return commands
    }

    // MARK: Running

    /// Sets aside the worktree's uncommitted changes to tracked files when some of
    /// them are in the way of the move, and says where they went. It's nil when
    /// nothing is in the way, so that git can run the move without rewriting
    /// files under someone's editor or agent. Untracked files stay where they are.
    static func setAside(for move: Move, message: String, in worktree: String, git: Git) async throws -> ChangesAside? {
        guard let head = try await head(in: worktree, git: git) else { return nil }
        let changed = try await names(["diff", "--name-only", "-z", "--no-renames", "HEAD", "--"], in: worktree, git: git)
        guard !changed.isEmpty else { return nil }
        // A file in conflict can't go into a stash, and git refuses the move anyway.
        guard try await conflicted(in: worktree, git: git).isEmpty else { return nil }
        var incoming: [String]?
        switch move {
        case .pull(_, rebases: true):
            break
        case .pull(let upstream, rebases: false):
            // What the upstream changed since the two lines parted is what a merge brings in.
            incoming = try await names(["diff", "--name-only", "-z", "--no-renames", "HEAD..." + upstream, "--"], in: worktree, git: git)
        case .reset(let commit), .detach(let commit):
            incoming = try await names(["diff", "--name-only", "-z", "--no-renames", "HEAD", commit.hex, "--"], in: worktree, git: git)
        }
        if let incoming, Set(incoming).isDisjoint(with: changed) { return nil }

        var symbolic = GitCommand("symbolic-ref", "--quiet", "HEAD", in: worktree)
        symbolic.successStatuses = [0, 1]
        let branch = try await git.text(symbolic)
        let before = try await newestStash(in: worktree, git: git)
        _ = try await IndexCommands.runningThroughLocks(RemoteCommands.asked(arguments(message: message), in: worktree), input: nil, git: git)
        // git saves nothing when the changes went in the meantime, such as into an
        // agent's commit, and the newest stash is then someone else's.
        guard let stash = try await newestStash(in: worktree, git: git), stash != before else { return nil }
        return ChangesAside(stash: stash, move: move, head: head, branch: branch.isEmpty ? nil : branch, message: message)
    }

    /// Puts the changes back where `HEAD` is now. When that stops on conflicts, git
    /// stages every file that came back cleanly, so the ones that weren't staged
    /// before go back to being unstaged.
    ///
    /// - Throws: `Missing` when the stash has gone from the list.
    func putBack(in worktree: String, git: Git) async throws -> PutBack {
        let arguments = try await popArguments(in: worktree, git: git)
        do {
            _ = try await IndexCommands.runningThroughLocks(RemoteCommands.asked(arguments, in: worktree), input: nil, git: git)
            return .back
        } catch let error as GitError {
            let conflicted = try await Self.conflicted(in: worktree, git: git)
            guard !conflicted.isEmpty else { return .stillAside(ran: arguments, said: error.message) }
            // The stash's second parent is its index, so this is what was staged.
            let index = stash.hex + "^2"
            let stagedBefore = Set(try await Self.names(["diff", "--name-only", "-z", "--no-renames", head.hex, index, "--"], in: worktree, git: git))
            let moved = Set(try await Self.names(["diff", "--name-only", "-z", "--no-renames", head.hex, "HEAD", "--"], in: worktree, git: git))
            let staged = try await Self.names(["diff", "--cached", "--name-only", "-z", "--no-renames"], in: worktree, git: git)
            let cleanlyBack = staged.filter { !Set(conflicted).contains($0) }
            try await IndexCommands.unstage(cleanlyBack.filter { !stagedBefore.contains($0) }, in: worktree, git: git)
            // A file the move left alone gets back exactly what was staged, which
            // matters when only some of its changes were. One the move changed keeps
            // all of it staged, because what was staged was against the old commit.
            let restoring = cleanlyBack.filter { stagedBefore.contains($0) && !moved.contains($0) }
            if !restoring.isEmpty {
                try await IndexCommands.run(
                    ["restore", "--staged", "--source=" + index, "--pathspec-from-file=-", "--pathspec-file-nul"],
                    paths: restoring,
                    in: worktree,
                    git: git
                )
            }
            return .conflicted(files: conflicted)
        }
    }

    /// Goes back to before the move and puts the changes back there, where they
    /// came from, so they fit unless something wrote to those files meanwhile.
    ///
    /// - Throws: `Missing` when the stash has gone from the list, or `GitError`.
    func undo(stopped: StoppedWork?, in worktree: String, git: Git) async throws -> PutBack {
        for arguments in undoArguments(stopped: stopped) {
            _ = try await IndexCommands.runningThroughLocks(RemoteCommands.asked(arguments, in: worktree), input: nil, git: git)
        }
        return try await putBack(in: worktree, git: git)
    }

    /// Pops the stash by its place in the list, which is the top unless someone
    /// stashed something since.
    private func popArguments(in worktree: String, git: Git) async throws -> [String] {
        var command = GitCommand("stash", "list", "--format=%H", in: worktree)
        command.successStatuses = [0, 1]
        let stashes = try await git.text(command).split(separator: "\n")
        guard let place = stashes.firstIndex(where: { $0 == stash.hex }) else { throw Missing(stash: stash) }
        return place == 0 ? Self.putBackArguments : Self.putBackArguments + ["stash@{\(place)}"]
    }

    private static func head(in worktree: String, git: Git) async throws -> ObjectID? {
        var command = GitCommand("rev-parse", "--verify", "--quiet", "HEAD^{commit}", in: worktree)
        command.successStatuses = [0, 1]
        return ObjectID(hex: try await git.text(command))
    }

    private static func newestStash(in worktree: String, git: Git) async throws -> ObjectID? {
        var command = GitCommand("rev-parse", "--verify", "--quiet", "refs/stash", in: worktree)
        command.successStatuses = [0, 1]
        return ObjectID(hex: try await git.text(command))
    }

    private static func conflicted(in worktree: String, git: Git) async throws -> [String] {
        try await names(["diff", "--name-only", "-z", "--diff-filter=U"], in: worktree, git: git)
    }

    /// The paths a command lists, each ending with a zero byte.
    private static func names(_ arguments: [String], in worktree: String, git: Git) async throws -> [String] {
        let output = try await git.run(GitCommand(arguments, in: worktree)).output
        return output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }
}
