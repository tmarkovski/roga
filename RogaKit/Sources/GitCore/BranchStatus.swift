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

/// How far a branch is from its upstream, without what pulling and pushing
/// need, for saying it about many branches at once.
public struct UpstreamCounts: Sendable, Hashable {
    public var ahead: Int
    public var behind: Int
    /// Whether its upstream has been deleted from the remote, which leaves
    /// nothing to count against.
    public var isGone: Bool

    public init(ahead: Int = 0, behind: Int = 0, isGone: Bool = false) {
        self.ahead = ahead
        self.behind = behind
        self.isGone = isGone
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

    /// What makes this the way a repository pulls from now on, for the two ways
    /// that someone chooses between.
    public var rememberArguments: [String]? {
        switch self {
        case .rebase: ["config", "pull.rebase", "true"]
        case .merge: ["config", "pull.rebase", "false"]
        case .fastForward, .configured: nil
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
    /// had. `--force-if-includes` is there because Roga fetches by itself
    /// (decision 20): a lease alone trusts the remote branch as it was last
    /// fetched, which may have brought in commits nobody has seen.
    case forceWithLease
    /// A branch other than the one checked out, to the remote branch it tracks.
    /// `onRemote` is what that's called there, when it isn't called the same.
    case otherBranch(String, remote: String, onRemote: String?)
    /// A branch other than the one checked out, to a remote that doesn't have it
    /// yet, which becomes its upstream.
    case otherBranchFirstTime(String, remote: String)

    public var arguments: [String] {
        switch self {
        case .toUpstream: ["push"]
        case .firstTime(let remote): ["push", "--set-upstream", remote, "HEAD"]
        case .forceWithLease: ["push", "--force-with-lease", "--force-if-includes"]
        case .otherBranch(let branch, let remote, let onRemote): ["push", remote, onRemote.map { "\(branch):\($0)" } ?? branch]
        case .otherBranchFirstTime(let branch, let remote): ["push", "--set-upstream", remote, branch]
        }
    }
}

/// A new branch, on the commit a worktree is on, or on another one.
public struct NewBranch: Sendable, Hashable {
    public var name: String
    /// Whether it gets a new worktree of its own, rather than the worktree
    /// switching to it.
    public var inNewWorktree: Bool
    /// The commit it starts from, when that isn't the one the worktree is on.
    public var startPoint: ObjectID?

    public init(name: String, inNewWorktree: Bool = false, startPoint: ObjectID? = nil) {
        self.name = name
        self.inNewWorktree = inNewWorktree
        self.startPoint = startPoint
    }

    /// Where its worktree goes: next to the worktree it's made from, named
    /// after the branch. A branch's name can have slashes in it, and a folder's
    /// shouldn't.
    public var folder: String {
        "../" + name.replacing("/", with: "-")
    }

    public var arguments: [String] {
        (inNewWorktree ? ["worktree", "add", "-b", name, folder] : ["switch", "-c", name]) + (startPoint.map { [$0.hex] } ?? [])
    }
}

/// A new lightweight tag on a commit.
public struct NewTag: Sendable, Hashable {
    public var name: String
    public var commit: ObjectID

    public init(name: String, commit: ObjectID) {
        self.name = name
        self.commit = commit
    }

    public var arguments: [String] {
        ["tag", name, commit.hex]
    }
}

/// A new remote, which pulls from one URL and can push to another.
public struct NewRemote: Sendable, Hashable {
    /// What's wrong with what's been typed, beside anything still being empty.
    public enum Problem: Sendable, Hashable {
        case nameTaken
        /// Has a space, or starts with a hyphen, which git would take for an option.
        case badName
        /// Starts with a hyphen, which git would take for an option.
        case badURL
    }

    public var name: String
    public var url: String
    /// Where it pushes, when that isn't `url`.
    public var pushURL: String?

    public init(name: String, url: String, pushURL: String? = nil) {
        self.name = name
        self.url = url
        self.pushURL = pushURL == url || pushURL?.isEmpty == true ? nil : pushURL
    }

    /// - Parameter remotes: The names of the remotes there are.
    public func problem(among remotes: [String]) -> Problem? {
        if remotes.contains(name) { return .nameTaken }
        if name.hasPrefix("-") || name.contains(where: \.isWhitespace) { return .badName }
        if url.hasPrefix("-") || pushURL?.hasPrefix("-") == true { return .badURL }
        return nil
    }

    /// Whether it's ready to add. git has the last word on the name.
    public func canBeAdded(among remotes: [String]) -> Bool {
        !name.isEmpty && !url.isEmpty && problem(among: remotes) == nil
    }

    /// What to run, in order, by their arguments after `git`.
    public var commands: [[String]] {
        [["remote", "add", name, url]] + (pushURL.map { [["remote", "set-url", "--push", name, $0]] } ?? [])
    }
}

/// Making a branch push to and pull from one of the repository's remotes.
public struct UpstreamChoice: Sendable, Hashable {
    /// The branch's short name.
    public var branch: String
    public var remote: String
    /// What the branch will track on the remote, or nil when the remote hasn't
    /// got it yet, and its first push goes there and sets that up.
    public var branchOnRemote: String?
    /// Whether the branch tracks something now, which has to go when the remote
    /// hasn't got it, or a pull would still come from the old remote.
    public var hasUpstream: Bool

    /// - Parameters:
    ///   - upstream: What the branch tracks now. It keeps tracking that name on
    ///     the new remote if the remote has it, and otherwise its own.
    ///   - exists: Whether a ref exists, by its full name.
    public init(branch: String, remote: String, upstream: RefRelation.Upstream?, exists: (String) -> Bool) {
        self.branch = branch
        self.remote = remote
        branchOnRemote = [upstream?.branchOnRemote, branch].compactMap(\.self).first { exists("\(Ref.remoteBranchPrefix)\(remote)/\($0)") }
        hasUpstream = upstream != nil
    }

    /// What to run, in order, by their arguments after `git`. Nothing here talks
    /// to the remote. `branch.<name>.pushRemote` is set either way, because a
    /// repository's `remote.pushDefault` would otherwise send the pushes elsewhere.
    public var commands: [[String]] {
        let pushRemote = ["config", "branch.\(branch).pushRemote", remote]
        if let branchOnRemote {
            // The full name, because a local branch could be called `fork/x` too.
            return [["branch", "--set-upstream-to=\(Ref.remoteBranchPrefix)\(remote)/\(branchOnRemote)", branch], pushRemote]
        }
        return (hasUpstream ? [["branch", "--unset-upstream", branch]] : []) + [pushRemote]
    }
}

/// A merge, a rebase, a revert or a cherry-pick that a worktree is partway
/// through, and what undoes it.
public enum StoppedWork: Sendable, Hashable {
    case merge
    /// `branch` is the full name of the branch being rebased, when it's on one.
    case rebase(branch: String?)
    /// `commit` is the one being reverted, from `REVERT_HEAD`, unless that file
    /// doesn't hold a commit's ID.
    case revert(commit: ObjectID?)
    /// `commit` is the one being applied, from `CHERRY_PICK_HEAD`, unless that
    /// file doesn't hold a commit's ID.
    case cherryPick(commit: ObjectID?)

    public var abortArguments: [String] {
        switch self {
        case .merge: ["merge", "--abort"]
        case .rebase: ["rebase", "--abort"]
        case .revert: ["revert", "--abort"]
        case .cherryPick: ["cherry-pick", "--abort"]
        }
    }
}

/// When a repository was last fetched, and what happened the last time Roga
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
