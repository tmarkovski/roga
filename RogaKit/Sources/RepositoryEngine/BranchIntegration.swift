import GitCore
import GitRunner

/// Bringing another branch into the worktree's branch by merging, fast-forwarding
/// or rebasing (decision 65), and what's worth knowing before that.
public struct BranchIntegration: Sendable, Hashable {
    public enum Way: Sendable, Hashable {
        /// `git merge --no-edit --ff`. `--ff` is there because someone who chose to
        /// merge wants that even if `merge.ff` says `only`.
        case merge
        /// `git merge --ff-only`, for a branch with nothing of its own to keep.
        case fastForward
        /// `git rebase`, which puts the branch's own commits on top of the other.
        case rebase
    }

    /// `HEAD` isn't where it was when this was worked out, so it would do something
    /// other than what someone agreed to.
    public struct Outdated: Error, Sendable, Hashable, CustomStringConvertible {
        public init() {}

        public var description: String {
            "Something else has moved HEAD since Roga worked out what this would do, so Roga left it there."
        }
    }

    public var way: Way
    /// The other branch's full name.
    public var ref: String
    /// What git is told, which is its short name unless that also names something else.
    public var typedName: String
    /// The worktree's branch by its full name, or nil when `HEAD` is detached.
    public var branch: String?
    /// Where `HEAD` was when this was worked out.
    public var head: ObjectID
    /// How many commits the other branch has that `HEAD` doesn't.
    public var incomingCount: Int
    /// How many commits `HEAD` has that the other branch doesn't.
    public var ownCount: Int
    /// How many of those are on the branch's upstream, which a rebase gives new
    /// hashes, so that pushing afterward takes a force push.
    public var pushedCount: Int
    /// The newest of the commits that matter here: what comes in for a merge, and
    /// what gets replayed for a rebase.
    public var listed: [ObjectID]

    public init(
        way: Way,
        ref: String,
        typedName: String? = nil,
        branch: String? = nil,
        head: ObjectID,
        incomingCount: Int = 0,
        ownCount: Int = 0,
        pushedCount: Int = 0,
        listed: [ObjectID] = []
    ) {
        self.way = way
        self.ref = ref
        self.typedName = typedName ?? Ref.shortName(ref)
        self.branch = branch
        self.head = head
        self.incomingCount = incomingCount
        self.ownCount = ownCount
        self.pushedCount = pushedCount
        self.listed = listed
    }

    /// What it runs, by its arguments after `git`.
    public var arguments: [String] {
        switch way {
        case .merge: ["merge", "--no-edit", "--ff", typedName]
        case .fastForward: ["merge", "--ff-only", typedName]
        case .rebase: ["rebase", typedName]
        }
    }

    /// What it means for uncommitted changes that are in the way (decision 59).
    public var move: ChangesAside.Move {
        switch way {
        case .merge, .fastForward: .merge(typedName)
        case .rebase: .rebase(onto: typedName)
        }
    }

    /// Finds out what bringing in a branch would come to.
    ///
    /// - Parameter limit: The most commits to list.
    static func prepare(_ way: Way, ref: String, limit: Int, in worktree: String, git: Git) async throws -> BranchIntegration {
        let refs = try await RefsLoader.load(git: git, in: worktree)
        guard let head = refs.head else { throw GitError.unexpectedReply(GitCommand("rev-parse", "HEAD", in: worktree), "no commit on HEAD") }
        let short = Ref.shortName(ref)
        let typed = refs.refs.count { $0.shortName == short } > 1 ? ref : short
        let (own, incoming) = try await counts(of: head.hex, against: ref, in: worktree, git: git)
        let upstream = refs.refs.first { $0.name == refs.currentBranch }?.upstream.flatMap { name in refs.refs.contains { $0.name == name } ? name : nil }
        var pushed = 0
        if way == .rebase, let upstream {
            let unpushed = try await count(["rev-list", "--count", head.hex, "^" + ref, "^" + upstream, "--"], in: worktree, git: git)
            pushed = own - unpushed
        }
        let range = way == .rebase ? "\(ref)..\(head.hex)" : "\(head.hex)..\(ref)"
        let listed = try await git.text(GitCommand("rev-list", "--max-count=\(limit)", range, "--", in: worktree))
            .split(separator: "\n")
            .compactMap { ObjectID(hex: String($0)) }
        return BranchIntegration(
            way: way,
            ref: ref,
            typedName: typed,
            branch: refs.currentBranch,
            head: head,
            incomingCount: incoming,
            ownCount: own,
            pushedCount: pushed,
            listed: listed
        )
    }

    /// How many commits only `left` has, and how many only `right` has.
    private static func counts(of left: String, against right: String, in worktree: String, git: Git) async throws -> (Int, Int) {
        let text = try await git.text(GitCommand("rev-list", "--count", "--left-right", "\(left)...\(right)", "--", in: worktree))
        let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard numbers.count == 2 else { throw GitError.unexpectedReply(GitCommand("rev-list", "--count", in: worktree), text) }
        return (numbers[0], numbers[1])
    }

    private static func count(_ arguments: [String], in worktree: String, git: Git) async throws -> Int {
        Int(try await git.text(GitCommand(arguments, in: worktree))) ?? 0
    }

    /// Whether `HEAD` is still where it was when this was worked out.
    func checkHead(in worktree: String, git: Git) async throws {
        var current = GitCommand("rev-parse", "--verify", "--quiet", "HEAD^{commit}", in: worktree)
        current.successStatuses = [0, 1]
        guard ObjectID(hex: try await git.text(current)) == head else { throw Outdated() }
    }

    /// Brings in the branch.
    ///
    /// - Throws: `GitError` when git refuses or stops on a conflict, which says why.
    func run(in worktree: String, git: Git) async throws {
        _ = try await git.run(RemoteCommands.asked(arguments, in: worktree))
    }
}

/// Applying one commit to the worktree's branch (decision 65), and what's worth
/// knowing before that.
public struct CommitCherryPick: Sendable, Hashable {
    /// The commit changes nothing that `HEAD` doesn't have already, so git has
    /// nothing to apply, and Roga has gone back to where it started.
    public struct AlreadyThere: Error, Sendable, Hashable, CustomStringConvertible {
        public var commit: ObjectID

        public var description: String {
            "Everything \(commit.hex.prefix(8)) changes is already here, so there's nothing to apply."
        }
    }

    public var commit: ObjectID
    public var subject: String
    public var parents: [ObjectID]
    /// Whether `HEAD` contains the commit already, which makes this probably a slip.
    public var headContains: Bool
    /// Where `HEAD` was when this was worked out.
    public var head: ObjectID?

    public init(commit: ObjectID, subject: String, parents: [ObjectID], headContains: Bool = false, head: ObjectID? = nil) {
        self.commit = commit
        self.subject = subject
        self.parents = parents
        self.headContains = headContains
        self.head = head
    }

    public var isMerge: Bool { parents.count > 1 }

    /// Whether someone should agree to this first: a merge can't be applied without
    /// choosing a side, and a commit that's already here is probably a slip.
    public var asksFirst: Bool { isMerge || headContains }

    /// What it runs, by its arguments after `git`.
    public var arguments: [String] {
        ["cherry-pick"] + (isMerge ? ["-m", "1"] : []) + [commit.hex]
    }

    static func prepare(_ commit: CommitInfo, in worktree: String, git: Git) async throws -> CommitCherryPick {
        var current = GitCommand("rev-parse", "--verify", "--quiet", "HEAD^{commit}", in: worktree)
        current.successStatuses = [0, 1]
        let head = ObjectID(hex: try await git.text(current))
        return CommitCherryPick(
            commit: commit.id,
            subject: commit.subject,
            parents: commit.parents,
            headContains: try await CommitRevert.headContains(commit.id, head: head, in: worktree, git: git),
            head: head
        )
    }

    /// Applies the commit, and returns the new one. When git stops because the
    /// commit turned out to change nothing, this skips it, so that the worktree
    /// isn't left partway through a commit with nothing in it.
    ///
    /// - Throws: `GitError` when git refuses or stops on a conflict, or
    ///   `AlreadyThere`.
    func run(in worktree: String, git: Git) async throws -> ObjectID {
        var current = GitCommand("rev-parse", "--verify", "--quiet", "HEAD^{commit}", in: worktree)
        current.successStatuses = [0, 1]
        guard ObjectID(hex: try await git.text(current)) == head else { throw BranchIntegration.Outdated() }
        do {
            _ = try await IndexCommands.runningThroughLocks(RemoteCommands.asked(arguments, in: worktree), input: nil, git: git)
        } catch let error as GitError {
            guard try await stoppedWithNothingToApply(in: worktree, git: git) else { throw error }
            _ = try await git.run(RemoteCommands.asked(["cherry-pick", "--skip"], in: worktree))
            throw AlreadyThere(commit: commit)
        }
        let after = try await git.text(GitCommand("rev-parse", "--verify", "HEAD^{commit}", in: worktree))
        guard let id = ObjectID(hex: after) else { throw GitError.unexpectedReply(current, "no commit on HEAD afterward") }
        return id
    }

    private func stoppedWithNothingToApply(in worktree: String, git: Git) async throws -> Bool {
        guard case .cherryPick = try await RemoteCommands.stoppedWork(in: worktree, git: git) else { return false }
        var staged = GitCommand("diff", "--cached", "--quiet", in: worktree)
        staged.successStatuses = [0, 1]
        return try await git.run(staged).status == 0
    }
}
