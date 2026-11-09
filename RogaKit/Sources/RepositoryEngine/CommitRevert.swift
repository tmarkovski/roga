import Foundation
import GitCore
import GitRunner

/// Reverting a commit in a worktree, against its `HEAD` (decision 44): what's worth
/// knowing before asking, and the two ways git can do it.
public struct CommitRevert: Sendable, Hashable {
    /// Whether git commits the revert straight away.
    public enum Way: Sendable, Hashable {
        /// `git revert --no-edit`, which commits with git's own message.
        case committing
        /// `git revert --no-commit`, which stages the reversed changes and leaves
        /// `REVERT_HEAD` and git's message in `MERGE_MSG` for the commit to come.
        case leavingUncommitted
    }

    /// How a revert came out, when git didn't refuse it.
    public enum Outcome: Sendable, Hashable {
        /// git made this commit.
        case committed(ObjectID)
        /// The reversed changes are staged, and the worktree is partway through the
        /// revert until they're committed.
        case leftUncommitted
        /// git stopped on conflicts, and the worktree is partway through the revert.
        case stoppedOnConflicts
    }

    /// The commit couldn't be read, as in a shallow clone that doesn't have it.
    public struct Missing: Error, Sendable, Hashable, CustomStringConvertible {
        public var commit: ObjectID

        public var description: String {
            "Roga can't read commit \(commit.hex.prefix(8)) in this repository."
        }
    }

    public var commit: ObjectID
    public var subject: String
    /// The commit's parents. A merge has more than one, and is reverted against the
    /// first, which keeps the line it was merged into and takes out what came from
    /// the others.
    public var parents: [ObjectID]
    /// Whether `HEAD` contains the commit. git reverts one it doesn't, too, by taking
    /// the commit's changes back out of whatever `HEAD` has.
    public var headContains: Bool
    /// How many files are staged, which is any difference between the index and
    /// `HEAD`. git won't commit a revert while there are any.
    public var stagedCount: Int
    /// Whether a pre-commit or commit-msg hook is set up. git commits a revert
    /// without running either.
    public var hasCommitHooks: Bool

    public init(commit: ObjectID, subject: String, parents: [ObjectID], headContains: Bool = true, stagedCount: Int = 0, hasCommitHooks: Bool = false) {
        self.commit = commit
        self.subject = subject
        self.parents = parents
        self.headContains = headContains
        self.stagedCount = stagedCount
        self.hasCommitHooks = hasCommitHooks
    }

    public var isMerge: Bool { parents.count > 1 }

    /// Whether git would commit the revert, which it only does when nothing's staged.
    public var canCommit: Bool { stagedCount == 0 }

    /// What reverting runs, by its arguments after `git`. A merge needs `-m 1` to
    /// say which parent's side to keep, and git refuses a merge without it.
    public func arguments(_ way: Way) -> [String] {
        let how = switch way {
        case .committing: "--no-edit"
        case .leavingUncommitted: "--no-commit"
        }
        return ["revert", how] + (isMerge ? ["-m", "1"] : []) + [commit.hex]
    }

    /// Finds out what's worth knowing before reverting a commit in a worktree.
    static func prepare(_ commit: CommitInfo, in worktree: String, format: ObjectFormat, git: Git) async throws -> CommitRevert {
        var current = GitCommand("rev-parse", "--verify", "--quiet", "HEAD^{commit}", in: worktree)
        current.successStatuses = [0, 1]
        let head = ObjectID(hex: try await git.text(current))

        async let contains = headContains(commit.id, head: head, in: worktree, git: git)
        async let staged = stagedCount(against: head ?? format.emptyTree, in: worktree, git: git)
        async let hooks = hasCommitHooks(in: worktree, git: git)
        return CommitRevert(
            commit: commit.id,
            subject: commit.subject,
            parents: commit.parents,
            headContains: try await contains,
            stagedCount: try await staged,
            hasCommitHooks: try await hooks
        )
    }

    static func headContains(_ commit: ObjectID, head: ObjectID?, in worktree: String, git: Git) async throws -> Bool {
        guard let head else { return false }
        var command = GitCommand("merge-base", "--is-ancestor", commit.hex, head.hex, in: worktree)
        command.successStatuses = [0, 1]
        return try await git.run(command).status == 0
    }

    /// How many files differ between the index and `HEAD`, which is what git
    /// checks before it commits a revert.
    private static func stagedCount(against tree: ObjectID, in worktree: String, git: Git) async throws -> Int {
        let output = try await git.run(GitCommand("diff-index", "--cached", "--name-only", "-z", tree.hex, "--", in: worktree)).output
        return output.count { $0 == 0 }
    }

    /// Whether the repository has a pre-commit or commit-msg hook, as a file where
    /// git looks for one, which follows `core.hooksPath`, or set up in its config.
    private static func hasCommitHooks(in worktree: String, git: Git) async throws -> Bool {
        let paths = try await git.text(GitCommand(
            "rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-commit", "--git-path", "hooks/commit-msg",
            in: worktree
        ))
        if paths.split(separator: "\n").contains(where: { FileManager.default.isExecutableFile(atPath: String($0)) }) { return true }
        var events = GitCommand("config", "--get-regexp", #"^hook\..*\.event$"#, in: worktree)
        events.successStatuses = [0, 1]
        return try await git.text(events).split(separator: "\n").contains { line in
            let event = line.split(separator: " ").last
            return event == "pre-commit" || event == "commit-msg"
        }
    }

    /// Reverts the commit. git stops with status 1 both on conflicts, which leave
    /// `REVERT_HEAD`, and when there's nothing to revert, which leaves none and only
    /// says why on standard output. So that's what a failure shows then.
    ///
    /// - Throws: `GitError` when git refuses, as it does when the worktree's changes
    ///   are in the way, which changes nothing.
    func run(_ way: Way, in worktree: String, git: Git) async throws -> Outcome {
        var command = RemoteCommands.asked(arguments(way), in: worktree)
        command.successStatuses = [0, 1]
        let result = try await IndexCommands.runningThroughLocks(command, input: nil, git: git)
        if result.status == 0 {
            switch way {
            case .committing:
                let head = try await git.text(GitCommand("rev-parse", "--verify", "HEAD^{commit}", in: worktree))
                guard let id = ObjectID(hex: head) else { throw GitError.unexpectedReply(command, "no commit on HEAD afterward") }
                return .committed(id)
            case .leavingUncommitted:
                return .leftUncommitted
            }
        }
        if case .revert = try await RemoteCommands.stoppedWork(in: worktree, git: git) { return .stoppedOnConflicts }
        let said = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.text : result.errorOutput
        throw GitError.failed(command, .exited(result.status), errorOutput: said)
    }
}
