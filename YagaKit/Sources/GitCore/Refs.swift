/// A branch, remote branch, tag or other ref.
public struct Ref: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A local branch, under `refs/heads/`.
        case branch
        /// A remote-tracking branch, under `refs/remotes/`.
        case remoteBranch
        /// A tag, under `refs/tags/`.
        case tag
        /// Anything else, such as `refs/stash`, notes or replace refs.
        case other
    }

    /// The full name, such as `refs/heads/main`.
    public var name: String
    /// The object the ref points to, which is a tag object for an annotated
    /// tag.
    public var target: ObjectID
    /// The object the ref leads to after following annotated tags. It's
    /// almost always a commit, but a tag can lead to a tree or a blob.
    public var peeled: ObjectID
    /// The full name of the ref this one stands for, such as
    /// `refs/remotes/origin/main` for `refs/remotes/origin/HEAD`, or nil when
    /// it isn't symbolic.
    public var symbolicTarget: String?
    /// The full name of the branch this one tracks, such as
    /// `refs/remotes/origin/main`, or nil when it doesn't track one. That
    /// branch may no longer exist.
    public var upstream: String?

    /// - Parameter peeled: What an annotated tag leads to, or nil for any
    ///   other ref, which leads to its target.
    public init(name: String, target: ObjectID, peeled: ObjectID? = nil, symbolicTarget: String? = nil, upstream: String? = nil) {
        self.name = name
        self.target = target
        self.peeled = peeled ?? target
        self.symbolicTarget = symbolicTarget
        self.upstream = upstream
    }

    public var kind: Kind {
        if name.hasPrefix(Self.branchPrefix) { .branch }
        else if name.hasPrefix(Self.remoteBranchPrefix) { .remoteBranch }
        else if name.hasPrefix(Self.tagPrefix) { .tag }
        else { .other }
    }

    /// The name without its prefix, such as `main`, `origin/main` or `v1.0`.
    public var shortName: String { Self.shortName(name) }

    /// The upstream, when it's a remote's branch of the same name, as
    /// `refs/remotes/origin/main` is for `main`. A remote whose name has a
    /// slash in it doesn't count, because a ref's name alone can't tell it from
    /// a branch whose name has one.
    public var upstreamOfSameName: String? {
        guard let upstream, upstream.hasPrefix(Self.remoteBranchPrefix) else { return nil }
        let remoteAndBranch = upstream.dropFirst(Self.remoteBranchPrefix.count)
        guard let slash = remoteAndBranch.firstIndex(of: "/"),
              remoteAndBranch[remoteAndBranch.index(after: slash)...] == shortName
        else { return nil }
        return upstream
    }

    /// Shortens a full ref name, such as `refs/heads/main` to `main`.
    public static func shortName(_ name: String) -> String {
        for prefix in [branchPrefix, remoteBranchPrefix, tagPrefix] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name.hasPrefix("refs/") ? String(name.dropFirst("refs/".count)) : name
    }

    public static let branchPrefix = "refs/heads/"
    public static let remoteBranchPrefix = "refs/remotes/"
    public static let tagPrefix = "refs/tags/"
}

/// Every ref in a repository, and what `HEAD` points to.
public struct RefList: Sendable, Hashable {
    /// The refs, sorted by name.
    public var refs: [Ref]
    /// The full name of the branch `HEAD` points to, or nil when `HEAD` is
    /// detached or its branch has no commits yet.
    public var currentBranch: String?
    /// The commit `HEAD` points to, or nil when there's none yet.
    public var head: ObjectID?

    public init(refs: [Ref] = [], currentBranch: String? = nil, head: ObjectID? = nil) {
        self.refs = refs
        self.currentBranch = currentBranch
        self.head = head
    }

    /// The branch that others are compared with when they have no upstream.
    /// That's the one a remote's `HEAD` names, preferring origin, and the
    /// local branch of that name if there is one. Without a remote's `HEAD`,
    /// it's a local `main` or `master`.
    public var mainBranch: Ref? {
        func ref(_ name: String) -> Ref? { refs.first { $0.name == name } }
        let remoteHeads = refs.filter { $0.kind == .remoteBranch && $0.symbolicTarget != nil && $0.name.hasSuffix("/HEAD") }
        let remoteHead = remoteHeads.first { $0.name == Ref.remoteBranchPrefix + "origin/HEAD" } ?? remoteHeads.first
        if let remoteHead, let target = remoteHead.symbolicTarget {
            let folder = remoteHead.name.dropLast("HEAD".count)
            return ref(Ref.branchPrefix + target.dropFirst(folder.count)) ?? ref(target)
        }
        return ref(Ref.branchPrefix + "main") ?? ref(Ref.branchPrefix + "master")
    }
}
