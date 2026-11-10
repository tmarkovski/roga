import GitCore
import GitRunner

/// How far `git reset` goes, beyond moving the branch.
public enum ResetMode: String, Sendable, Hashable, CaseIterable {
    /// `--keep`, which carries uncommitted changes along, and refuses when they're
    /// in the way.
    case keep
    /// `--soft`, which leaves the files and the index alone.
    case soft
    /// `--mixed`, which leaves the files alone and empties the index.
    case mixed
    /// `--hard`, which makes the files and the index match the commit.
    case hard
}

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
    /// Whether the branch itself leads to the commit, which makes everything since
    /// then the branch's own. An upstream can lead there without the branch doing so.
    public var goesBack: Bool
    /// How far a reset goes. Going to a commit by double-clicking it is always `.keep`.
    public private(set) var mode = ResetMode.keep

    /// Whether this leaves the files and the index as they are.
    public var keepsChanges: Bool { mode == .soft }

    public init(commit: ObjectID, way: Way, head: ObjectID? = nil, lostCount: Int = 0, lost: [ObjectID] = [], goesBack: Bool = false) {
        self.commit = commit
        self.way = way
        self.head = head
        self.lostCount = lostCount
        self.lost = lost
        self.goesBack = goesBack
    }

    /// Whether someone should agree to this first, which is only when it loses
    /// commits.
    public var asksFirst: Bool { lostCount > 0 }

    /// What going there runs, which the dialog shows. `--keep` is there because it
    /// carries uncommitted changes along, and refuses when they're in the way.
    public var arguments: [String] {
        switch way {
        case .movingBranch: ["reset", "--" + mode.rawValue, commit.hex]
        case .detaching: ["switch", "--detach", commit.hex]
        }
    }

    /// The same move with `--soft`, so that everything since the commit comes back
    /// as staged changes. It's only for going back: across a branch that has diverged,
    /// those changes would also undo whatever is on the other side.
    public var keepingChanges: CommitSwitch? {
        guard goesBack else { return nil }
        return resetting(.soft)
    }

    /// The same move, going as far as `mode` says.
    public func resetting(_ mode: ResetMode) -> CommitSwitch {
        var reset = self
        reset.mode = mode
        return reset
    }

    /// Finds out what going to a commit would come to.
    ///
    /// - Parameters:
    ///   - limit: The most commits to list.
    ///   - movingTheBranch: Whether the branch moves wherever the commit is, as a
    ///     reset someone asked for by name does, rather than `HEAD` leaving it.
    static func prepare(to commit: ObjectID, limit: Int, in worktree: String, worktrees: [Worktree], movingTheBranch: Bool = false, git: Git) async throws -> CommitSwitch {
        let refs = try await RefsLoader.load(git: git, in: worktree)
        var way = Way.detaching
        var goesBack = false
        var leaving: [String] = []
        if let branch = refs.currentBranch {
            let upstream = refs.refs.first { $0.name == branch }?.upstream
            let holders = try await holders(of: commit, among: [branch, upstream].compactMap(\.self), in: worktree, git: git)
            if !holders.isEmpty || movingTheBranch {
                way = .movingBranch(branch)
                goesBack = holders.contains(branch)
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
        return CommitSwitch(commit: commit, way: way, head: refs.head, lostCount: lost.count, lost: lost.newest, goesBack: goesBack)
    }

    /// Which of these refs lead to a commit.
    private static func holders(of commit: ObjectID, among refs: [String], in worktree: String, git: Git) async throws -> [String] {
        let holders = try await git.text(GitCommand(["for-each-ref", "--contains=" + commit.hex, "--format=%(refname)"] + refs, in: worktree))
        return holders.split(separator: "\n").map(String.init)
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
