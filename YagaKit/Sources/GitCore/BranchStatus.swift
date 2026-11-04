import Foundation

/// Where a worktree's branch stands against its upstream, and what pulling and
/// pushing it would take (decision 19).
public struct BranchStatus: Sendable, Hashable {
    /// The branch's full name.
    public var branch: String
    /// The full name of its upstream, unless it has none or that's gone.
    public var upstream: String?
    /// Whether its upstream has been deleted from the remote.
    public var upstreamIsGone: Bool
    /// How many commits it has that its upstream doesn't.
    public var ahead: Int
    /// How many commits its upstream has that it doesn't.
    public var behind: Int
    /// The remote to fetch from, which is the one it tracks, or `origin` when it
    /// tracks none. It's nil when the repository has neither (decision 20).
    public var remote: String?
    /// The remote a first push goes to, or nil when there's none.
    public var pushRemote: String?
    /// What `branch.<name>.rebase` or `pull.rebase` says, or nil when neither
    /// is set.
    public var pullRebase: String?

    public init(
        branch: String,
        upstream: String? = nil,
        upstreamIsGone: Bool = false,
        ahead: Int = 0,
        behind: Int = 0,
        remote: String? = nil,
        pushRemote: String? = nil,
        pullRebase: String? = nil
    ) {
        self.branch = branch
        self.upstream = upstream
        self.upstreamIsGone = upstreamIsGone
        self.ahead = ahead
        self.behind = behind
        self.remote = remote
        self.pushRemote = pushRemote
        self.pullRebase = pullRebase
    }

    /// Whether git would have to combine the branch with its upstream to pull,
    /// and would reject a push.
    public var hasDiverged: Bool { ahead > 0 && behind > 0 }

    /// What clicking to pull runs, which is nil when there's nothing to pull, or
    /// when the branch has diverged and the user's configuration doesn't say
    /// whether to rebase or merge.
    public var pull: Pull? {
        guard behind > 0 else { return nil }
        if ahead == 0 { return .fastForward }
        return pullRebase == nil ? nil : .configured
    }

    /// What clicking to push runs, or nil when there's nothing to push, or when
    /// git would reject the push because the branch is behind.
    public var push: Push? {
        if upstream == nil { return pushRemote.map(Push.firstTime) }
        return ahead > 0 && behind == 0 ? .toUpstream : nil
    }
}

/// A way of pulling a worktree's branch.
public enum Pull: Sendable, Hashable {
    /// For a branch that's only behind.
    case fastForward
    /// Does what the user's configuration says.
    case configured
    case rebase
    /// `--ff` is there because someone who chose to merge wants that even if
    /// `pull.ff` says `only`.
    case merge

    public var arguments: [String] {
        switch self {
        case .fastForward: ["pull", "--ff-only"]
        case .configured: ["pull"]
        case .rebase: ["pull", "--rebase"]
        case .merge: ["pull", "--no-rebase", "--ff"]
        }
    }
}

/// A way of pushing a worktree's branch.
public enum Push: Sendable, Hashable {
    /// To the branch's upstream.
    case toUpstream
    /// To a remote that doesn't have the branch yet, which becomes its upstream.
    case firstTime(remote: String)
    /// Overwrites the upstream, unless it has commits that the branch never
    /// had. `--force-if-includes` is there because yaga fetches by itself
    /// (decision 20): a lease alone trusts the remote branch as it was last
    /// fetched, which may have brought in commits nobody has seen.
    case forceWithLease

    public var arguments: [String] {
        switch self {
        case .toUpstream: ["push"]
        case .firstTime(let remote): ["push", "--set-upstream", remote, "HEAD"]
        case .forceWithLease: ["push", "--force-with-lease", "--force-if-includes"]
        }
    }
}

/// A new branch, on the commit a worktree is on.
public struct NewBranch: Sendable, Hashable {
    public var name: String
    /// Whether it gets a new worktree of its own, rather than the worktree
    /// switching to it.
    public var inNewWorktree: Bool

    public init(name: String, inNewWorktree: Bool = false) {
        self.name = name
        self.inNewWorktree = inNewWorktree
    }

    /// Where its worktree goes: next to the worktree it's made from, named
    /// after the branch. A branch's name can have slashes in it, and a folder's
    /// shouldn't.
    public var folder: String {
        "../" + name.replacing("/", with: "-")
    }

    public var arguments: [String] {
        inNewWorktree ? ["worktree", "add", "-b", name, folder] : ["switch", "-c", name]
    }
}

/// A merge or a rebase that a worktree is partway through, and what undoes it.
public enum StoppedWork: Sendable, Hashable {
    case merge
    /// `branch` is the full name of the branch being rebased, when it's on one.
    case rebase(branch: String?)

    public var abortArguments: [String] {
        switch self {
        case .merge: ["merge", "--abort"]
        case .rebase: ["rebase", "--abort"]
        }
    }
}

/// When a repository was last fetched, and what happened the last time yaga
/// tried.
public struct FetchRecord: Sendable, Hashable {
    /// When a fetch last worked, or nil when nothing says so.
    public var lastFetched: Date?
    /// What git said when the latest fetch failed, or nil when it worked.
    public var failure: String?

    public init(lastFetched: Date? = nil, failure: String? = nil) {
        self.lastFetched = lastFetched
        self.failure = failure
    }
}
