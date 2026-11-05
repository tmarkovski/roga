import GitCore
import GitRunner

/// What going to a commit would come to, which says whether to ask first
/// (decision 37).
public struct CommitSwitch: Sendable, Hashable {
    /// How a worktree gets to the commit.
    public enum Way: Sendable, Hashable {
        /// The branch moves to the commit, which is on its line because the branch
        /// or its upstream leads there. This has the branch's full name.
        case movingBranch(String)
        /// `HEAD` goes to the commit, and any branch stays where it is.
        case detaching
    }

    /// `HEAD` isn't where it was when this was worked out, so it may lose more than
    /// someone agreed to.
    public struct Outdated: Error, Sendable, Hashable, CustomStringConvertible {
        public init() {}

        public var description: String {
            "Something else has moved HEAD since Roga counted what this would lose, so Roga left it there."
        }
    }

    public var commit: ObjectID
    public var way: Way
    /// Where `HEAD` was when this was worked out, or nil when it had no commit.
    public var head: ObjectID?
    /// How many commits nothing would lead to afterward: no branch, remote branch
    /// or tag, and no other worktree's `HEAD`.
    public var lostCount: Int
    /// The newest of those commits.
    public var lost: [ObjectID]

    public init(commit: ObjectID, way: Way, head: ObjectID? = nil, lostCount: Int = 0, lost: [ObjectID] = []) {
        self.commit = commit
        self.way = way
        self.head = head
        self.lostCount = lostCount
        self.lost = lost
    }

    /// Whether someone should agree to this first, which is only when it loses
    /// commits.
    public var asksFirst: Bool { lostCount > 0 }

    /// What going there runs, which the dialog shows. `--keep` is there because it
    /// carries uncommitted changes along, and refuses when they're in the way.
    public var arguments: [String] {
        switch way {
        case .movingBranch: ["reset", "--keep", commit.hex]
        case .detaching: ["switch", "--detach", commit.hex]
        }
    }

    /// Finds out what going to a commit would come to.
    ///
    /// - Parameter limit: The most commits to list.
    static func prepare(to commit: ObjectID, limit: Int, in worktree: String, worktrees: [Worktree], git: Git) async throws -> CommitSwitch {
        let refs = try await RefsLoader.load(git: git, in: worktree)
        var way = Way.detaching
        var leaving: [String] = []
        if let branch = refs.currentBranch {
            let upstream = refs.refs.first { $0.name == branch }?.upstream
            if try await any(of: [branch, upstream].compactMap(\.self), contains: commit, in: worktree, git: git) {
                way = .movingBranch(branch)
                leaving = LostCommits.leaving([branch], among: refs.refs)
            }
        }
        // This worktree's own `HEAD` is what's going. Leaving out every worktree on
        // that commit can only make this ask when it needn't have, whereas missing
        // this one because its folder is spelled differently would hide every loss.
        let otherHeads = worktrees.compactMap(\.head).filter { $0 != refs.head }.map(\.hex)
        let lost = try await LostCommits.find(
            from: refs.head.map { [$0.hex] } ?? [],
            leaving: leaving,
            keeping: ["--glob=refs/*", commit.hex] + otherHeads,
            limit: limit,
            in: worktree,
            git: git
        )
        return CommitSwitch(commit: commit, way: way, head: refs.head, lostCount: lost.count, lost: lost.newest)
    }

    /// Whether any of these refs leads to a commit.
    private static func any(of refs: [String], contains commit: ObjectID, in worktree: String, git: Git) async throws -> Bool {
        let holders = try await git.text(GitCommand(["for-each-ref", "--contains=" + commit.hex, "--format=%(refname)"] + refs, in: worktree))
        return !holders.isEmpty
    }

    /// Goes to the commit, unless `HEAD` has moved since this was worked out, which
    /// can happen while a dialog waits and an agent commits.
    func run(in worktree: String, git: Git) async throws {
        var current = GitCommand("rev-parse", "--verify", "--quiet", "HEAD^{commit}", in: worktree)
        current.successStatuses = [0, 1]
        guard ObjectID(hex: try await git.text(current)) == head else { throw Outdated() }
        _ = try await git.run(RemoteCommands.asked(arguments, in: worktree))
    }
}
