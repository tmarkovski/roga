import Foundation
import GitCore
import GitRunner

/// A commit that someone asked for. The message goes to the user's own git, so
/// their hooks run and their commits get signed, as at the command line.
public struct CommitRequest: Sendable, Hashable {
    public var message: String
    /// Whether it replaces the commit `HEAD` is on.
    public var amends = false
    /// Whether to leave out the pre-commit and commit-msg hooks.
    public var skipsHooks = false

    public init(message: String, amends: Bool = false, skipsHooks: Bool = false) {
        self.message = message
        self.amends = amends
        self.skipsHooks = skipsHooks
    }

    /// `-F -` reads the message from standard input, and it leaves lines that
    /// start with `#` alone, as `-m` does.
    var arguments: [String] {
        ["commit", "-F", "-"] + (amends ? ["--amend"] : []) + (skipsHooks ? ["--no-verify"] : [])
    }
}

/// A commit that Roga just made, and what's needed to take it back.
public struct MadeCommit: Sendable, Hashable {
    public var id: ObjectID
    /// The commit `HEAD` was on before, or nil when this was the first.
    public var previous: ObjectID?

    public init(id: ObjectID, previous: ObjectID?) {
        self.id = id
        self.previous = previous
    }
}

/// `HEAD` isn't on the commit someone asked to undo any more.
public struct HeadMoved: Error, Sendable, Hashable, CustomStringConvertible {
    public init() {}

    public var description: String {
        "Something else has moved HEAD since that commit, so undoing it would lose what came after."
    }
}

/// The commit someone asked to undo has been pushed, whether by Roga, at the
/// command line or by an agent.
public struct CommitPushed: Error, Sendable, Hashable, CustomStringConvertible {
    /// The short name of a remote branch that has it, such as `origin/main`.
    public var remoteBranch: String

    public init(remoteBranch: String) {
        self.remoteBranch = remoteBranch
    }

    public var description: String {
        "\(remoteBranch) has that commit now, so undoing it here would leave the branch behind what's been pushed. "
            + "To take its changes back, revert it from its row in history."
    }
}

/// The commands that change what's in a worktree's index, and that make commits
/// from it. They're the only ones that write the index on purpose, so they run
/// only because someone asked (decision 30).
enum IndexCommands {
    /// How many times to try again while another git holds the index lock.
    static let lockRetries = 6
    /// How long to wait before the first try again. Each wait is longer than the
    /// one before, which comes to about 4 seconds altogether.
    static let lockRetryDelay = Duration.milliseconds(150)

    /// Puts files into the index as they are on disk now, including removing
    /// the ones that are gone.
    static func stage(_ paths: [String], in worktree: String, git: Git) async throws {
        guard !paths.isEmpty else { return }
        try await run(["add", "--all", "--pathspec-from-file=-", "--pathspec-file-nul"], paths: paths, in: worktree, git: git)
    }

    /// Puts everything in the worktree into the index, except what's at
    /// `paths`, which are submodules that staging would take commits away from
    /// (decision 75).
    ///
    /// Leaving a path out takes a pathspec that says so, and git reads none of
    /// those while `GIT_LITERAL_PATHSPECS` is set. Each path says for itself
    /// that it's a name rather than a pattern, and that it's from the top of
    /// the worktree.
    static func stageEverything(in worktree: String, leavingOut paths: [String] = [], git: Git) async throws {
        guard !paths.isEmpty else {
            try await run(["add", "--all"], paths: nil, in: worktree, git: git)
            return
        }
        let command = RemoteCommands.asked(stageEverythingArguments(leavingOut: paths), in: worktree)
        _ = try await runningThroughLocks(command, input: nil, git: git)
    }

    static func stageEverythingArguments(leavingOut paths: [String]) -> [String] {
        ["add", "--all", "--", ":(top)"] + paths.map { ":(top,exclude,literal)" + $0 }
    }

    /// Takes files back out of the index, leaving them as they are on disk.
    ///
    /// `git reset` rather than `git restore --staged`, because it also works
    /// before the first commit, when there's no `HEAD` to restore from.
    static func unstage(_ paths: [String], in worktree: String, git: Git) async throws {
        guard !paths.isEmpty else { return }
        try await run(["reset", "--quiet", "--pathspec-from-file=-", "--pathspec-file-nul"], paths: paths, in: worktree, git: git)
    }

    /// Makes a commit from the index, and says which.
    static func commit(_ request: CommitRequest, in worktree: String, git: Git) async throws -> MadeCommit {
        let previous = try await head(in: worktree, git: git)
        let command = RemoteCommands.asked(request.arguments, in: worktree)
        _ = try await runningThroughLocks(command, input: Array(request.message.utf8), git: git)
        guard let id = try await head(in: worktree, git: git) else {
            throw GitError.unexpectedReply(command, "no commit on HEAD afterward")
        }
        return MadeCommit(id: id, previous: previous)
    }

    /// Takes back a commit Roga made, leaving what it had in the index.
    ///
    /// - Throws: `HeadMoved` when `HEAD` has moved on, because resetting then
    ///   would lose what moved it, such as an agent's commit. `CommitPushed`
    ///   when a remote branch has the commit, because resetting then would
    ///   leave the branch behind it.
    static func undo(_ commit: MadeCommit, in worktree: String, git: Git) async throws {
        guard let previous = commit.previous else { throw HeadMoved() }
        guard try await head(in: worktree, git: git) == commit.id else { throw HeadMoved() }
        if let pushed = try await remoteBranches(containing: commit.id, in: worktree, git: git).first {
            throw CommitPushed(remoteBranch: Ref.shortName(pushed))
        }
        _ = try await runningThroughLocks(
            RemoteCommands.asked(["reset", "--quiet", "--soft", previous.hex], in: worktree),
            input: nil,
            git: git
        )
    }

    /// Goes on with a rebase that stopped, keeping the message of the commit it
    /// stopped on.
    static func continueRebase(in worktree: String, git: Git) async throws {
        _ = try await git.run(RemoteCommands.asked(["rebase", "--continue"], in: worktree))
    }

    /// The message git has ready for what a worktree is partway through, without
    /// the lines git would leave out as comments.
    static func message(for work: StoppedWork, in worktree: String, git: Git) async throws -> String? {
        let name = switch work {
        case .merge, .revert, .cherryPick: "MERGE_MSG"
        case .rebase: "rebase-merge/message"
        }
        let path = try await git.text(GitCommand("rev-parse", "--path-format=absolute", "--git-path", name, in: worktree))
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }
        let message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    /// The full names of the remote branches that lead to a commit, as this
    /// repository last heard of them from a fetch or a push. That leaves out
    /// a remote's `HEAD`, which only says which of its branches is the default.
    private static func remoteBranches(containing commit: ObjectID, in worktree: String, git: Git) async throws -> [String] {
        let names = try await git.text(GitCommand(
            "for-each-ref", "--contains=" + commit.hex, "--format=%(if)%(symref)%(then)%(else)%(refname)%(end)", "refs/remotes/",
            in: worktree
        ))
        return names.split(separator: "\n").map(String.init)
    }

    /// The commit `HEAD` is on, or nil before the first commit.
    private static func head(in worktree: String, git: Git) async throws -> ObjectID? {
        var command = GitCommand("rev-parse", "--verify", "--quiet", "HEAD^{commit}", in: worktree)
        command.successStatuses = [0, 1]
        return ObjectID(hex: try await git.text(command))
    }

    static func run(_ arguments: [String], paths: [String]?, in worktree: String, git: Git) async throws {
        var command = RemoteCommands.asked(arguments, in: worktree)
        // A file can be called `*.txt`, and `:(top)a` is a file's name here too.
        command.environment["GIT_LITERAL_PATHSPECS"] = "1"
        // Each path ends with a zero byte, as `--pathspec-file-nul` asks for.
        let input: [UInt8]? = paths.map { paths in paths.flatMap { path -> [UInt8] in Array(path.utf8) + [0] } }
        _ = try await runningThroughLocks(command, input: input, git: git)
    }

    /// Runs a command that needs the index, waiting for any other git that has it,
    /// such as an agent's, for a moment before giving up.
    static func runningThroughLocks(_ command: GitCommand, input: [UInt8]?, git: Git) async throws -> GitResult {
        var delay = lockRetryDelay
        for _ in 0..<lockRetries {
            do {
                return try await git.run(command, input: input)
            } catch let error as GitError where error.isAboutALock {
                try await Task.sleep(for: delay)
                delay = delay * 3 / 2
            }
        }
        return try await git.run(command, input: input)
    }
}

private extension GitError {
    /// Whether git refused because another git has the index, which goes away by
    /// itself. A lock left behind by a crash doesn't, and git's message for that
    /// is what someone ends up seeing.
    var isAboutALock: Bool {
        guard case .failed(_, _, let output) = self else { return false }
        return output.contains("index.lock") && output.contains("File exists")
    }
}
