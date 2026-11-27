/// What the refs panel lists about a repository: its branches, remotes, tags
/// and stashes, with more about each than `RefList` has.
public struct RefDetails: Sendable, Hashable {
    /// The full name of the branch `HEAD` points to in the worktree these
    /// were read for, or nil when `HEAD` is detached.
    public var currentBranch: String?
    /// The local branches, sorted by name.
    public var branches: [BranchDetails]
    /// The remotes, sorted by name, each with its branches.
    public var remotes: [RemoteDetails]
    /// The tags, sorted by name.
    public var tags: [TagDetails]
    /// The stashes, from the latest to the oldest.
    public var stashes: [StashDetails]

    public init(
        currentBranch: String? = nil,
        branches: [BranchDetails] = [],
        remotes: [RemoteDetails] = [],
        tags: [TagDetails] = [],
        stashes: [StashDetails] = []
    ) {
        self.currentBranch = currentBranch
        self.branches = branches
        self.remotes = remotes
        self.tags = tags
        self.stashes = stashes
    }
}

/// A local branch.
public struct BranchDetails: Sendable, Hashable {
    /// The full name, such as `refs/heads/main`.
    public var name: String
    /// The commit the branch points to.
    public var tip: ObjectID
    /// When the tip was committed, in seconds since 1970.
    public var date: Int64?
    /// The folder of the worktree that has it checked out, if any has.
    public var worktree: String?
    /// Whether that worktree is locked, which often means an agent is working
    /// in it.
    public var isWorktreeLocked: Bool
    /// How far it is from the branch it's compared with, if there's one: its
    /// upstream, or without one, the main branch.
    public var comparison: BranchComparison?
    /// The full name of its upstream, as in `refs/remotes/origin/main`, while
    /// the remote still has it.
    public var upstream: String?
    /// The full name of an upstream that's gone from its remote, as after a
    /// fetch that prunes once a pull request is merged.
    public var goneUpstream: String?
    /// How far it is from the main branch, whether or not it has an upstream.
    /// Nil for the main branch itself, and without one.
    public var main: BranchComparison?
    /// Whether its work is all in the main branch already: it has no commits
    /// that the main branch, its upstream or the remote's main branch doesn't,
    /// and it has moved since it was made. That second part comes from its
    /// reflog, and keeps a branch that was just made from an older main
    /// branch from counting before it has a commit of its own.
    public var isMerged: Bool

    public init(
        name: String,
        tip: ObjectID,
        date: Int64? = nil,
        worktree: String? = nil,
        isWorktreeLocked: Bool = false,
        comparison: BranchComparison? = nil,
        upstream: String? = nil,
        goneUpstream: String? = nil,
        main: BranchComparison? = nil,
        isMerged: Bool = false
    ) {
        self.name = name
        self.tip = tip
        self.date = date
        self.worktree = worktree
        self.isWorktreeLocked = isWorktreeLocked
        self.comparison = comparison
        self.upstream = upstream
        self.goneUpstream = goneUpstream
        self.main = main
        self.isMerged = isMerged
    }

    public var shortName: String { Ref.shortName(name) }
}

/// How far a branch is from another. A branch is compared with its upstream,
/// and without one, with the repository's main branch.
public struct BranchComparison: Sendable, Hashable {
    /// The other branch's short name, such as `origin/main` or `main`.
    public var other: String
    /// How many commits this branch has that the other doesn't.
    public var ahead: Int
    /// How many commits the other branch has that this one doesn't.
    public var behind: Int

    public init(other: String, ahead: Int, behind: Int) {
        self.other = other
        self.ahead = ahead
        self.behind = behind
    }
}

/// A remote and the branches Roga knows it has, which are the ones it had the
/// last time something fetched from it.
public struct RemoteDetails: Sendable, Hashable {
    public var name: String
    /// Where it is, in the form that `RemoteAddress.shown(_:)` gives, or nil
    /// for a remote that has branches left but isn't configured any more.
    public var address: String?
    /// Its branches, sorted by name. Symbolic refs such as `origin/HEAD`
    /// aren't branches of their own, so they aren't here.
    public var branches: [RemoteBranchDetails]

    public init(name: String, address: String? = nil, branches: [RemoteBranchDetails] = []) {
        self.name = name
        self.address = address
        self.branches = branches
    }

    /// Puts remote-tracking branches under their remotes. Remote names can
    /// have slashes in them, so a branch goes under the longest name it starts
    /// with, and otherwise under the first part of its name.
    ///
    /// - Parameter addresses: The address of each configured remote, by name.
    public static func grouping(_ branches: [RemoteBranchDetails], addresses: [String: String]) -> [RemoteDetails] {
        let longestFirst = addresses.keys.sorted { $0.count > $1.count }
        var remotes = addresses.mapValues { RemoteDetails(name: "", address: $0) }
        for (name, _) in addresses { remotes[name]?.name = name }
        for var branch in branches {
            let full = branch.shortName
            let remote = remoteName(of: full, amongLongestFirst: longestFirst)
            branch.shortName = String(full.dropFirst(remote.count + 1))
            remotes[remote, default: RemoteDetails(name: remote)].branches.append(branch)
        }
        return remotes.values.sorted { $0.name < $1.name }
    }

    /// Which remote a remote branch such as `origin/main` belongs to. A remote's
    /// name can have slashes in it, so the longest one that fits wins. Without
    /// a configured one, it's the part before the first slash, as git assumes.
    ///
    /// - Parameter names: The configured remotes, from the longest name to the
    ///   shortest.
    public static func remoteName(of branch: String, amongLongestFirst names: [String]) -> String {
        names.first { branch.hasPrefix($0 + "/") } ?? String(branch.prefix { $0 != "/" })
    }
}

/// A remote-tracking branch.
public struct RemoteBranchDetails: Sendable, Hashable {
    /// The full name, such as `refs/remotes/origin/main`.
    public var name: String
    /// The name on the remote, such as `main`, once it's under its remote.
    public var shortName: String
    public var tip: ObjectID
    /// When the tip was committed, in seconds since 1970.
    public var date: Int64?
    /// How far it is from the main branch, as for a local branch. Nil without
    /// a main branch.
    public var main: BranchComparison?
    /// Whether its work is all in the main branch already: it has no commits
    /// that the main branch, its upstream or the remote's main branch doesn't,
    /// and the main branch has moved on past it. It's never true of a remote's
    /// own main branch.
    public var isMerged: Bool

    public init(name: String, shortName: String? = nil, tip: ObjectID, date: Int64? = nil, main: BranchComparison? = nil, isMerged: Bool = false) {
        self.name = name
        self.shortName = shortName ?? Ref.shortName(name)
        self.tip = tip
        self.date = date
        self.main = main
        self.isMerged = isMerged
    }
}

/// A tag.
public struct TagDetails: Sendable, Hashable {
    /// The full name, such as `refs/tags/v1.0`.
    public var name: String
    /// The commit it points to, or nil when it points to something else, such
    /// as the tree that Linux's oldest tag points to.
    public var commit: ObjectID?
    /// When it was made, for an annotated tag, or when its commit was made,
    /// in seconds since 1970. Old tags can be missing the date.
    public var date: Int64?
    /// The subject of its commit, once that's been read.
    public var subject: String?

    public init(name: String, commit: ObjectID? = nil, date: Int64? = nil, subject: String? = nil) {
        self.name = name
        self.commit = commit
        self.date = date
        self.subject = subject
    }

    public var shortName: String { Ref.shortName(name) }
}

/// A stash.
public struct StashDetails: Sendable, Hashable {
    /// Its place among the stashes, where the latest is 0, as in `stash@{0}`.
    public var position: Int
    public var commit: ObjectID
    /// When it was made, in seconds since 1970.
    public var date: Int64?
    /// What git or the user called it, as in `WIP on main: 5405371 Fix it`.
    public var message: String

    public init(position: Int, commit: ObjectID, date: Int64? = nil, message: String) {
        self.position = position
        self.commit = commit
        self.date = date
        self.message = message
    }

    /// What git calls it, as in `stash@{0}`.
    public var name: String { "stash@{\(position)}" }

    /// The branch it was made on, from the start of its message, as in `main`
    /// for `On main: Fix it`, or nil when the message doesn't say or `HEAD`
    /// was detached (decision 81).
    public var branch: String? { Self.parts(of: message).branch }

    /// Its message without the branch git puts at its start, as in `Fix it` for
    /// `On main: Fix it`, and `WIP on 5405371 Fix it` for
    /// `WIP on main: 5405371 Fix it`, since the row names the branch elsewhere.
    public var title: String { Self.parts(of: message).title }

    static func parts(of message: String) -> (branch: String?, title: String) {
        for (prefix, kept) in [("On ", ""), ("WIP on ", "WIP on ")] {
            guard message.hasPrefix(prefix), let colon = message.firstRange(of: ": ") else { continue }
            let branch = String(message[message.index(message.startIndex, offsetBy: prefix.count)..<colon.lowerBound])
            // A branch's name can't have a space or a colon, so anything else
            // isn't one. git says `(no branch)` for a detached `HEAD`.
            let isDetached = branch == "(no branch)"
            guard !branch.isEmpty, isDetached || !branch.contains(" ") else { continue }
            return (isDetached ? nil : branch, kept + message[colon.upperBound...])
        }
        return (nil, message)
    }
}

/// Shortens a remote's URL for showing it.
public enum RemoteAddress {
    /// The host and path of a URL, as in `github.com/torvalds/linux.git`.
    /// A local path stays as it is.
    ///
    /// It leaves out the user name and password, because a URL with a token in
    /// it is a secret that shouldn't be on the screen.
    public static func shown(_ url: String) -> String {
        if let scheme = url.firstRange(of: "://") {
            let rest = url[scheme.upperBound...]
            // A file URL has no host, so what's left is the path.
            let path = rest.firstIndex(of: "/") ?? rest.endIndex
            let authority = rest[..<path]
            let host = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
            return String(host + rest[path...])
        }
        // git treats host:path as a host and a path, unless a slash comes
        // before the colon, which makes it a local path.
        guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return url }
        let authority = url[..<colon]
        let host = authority.lastIndex(of: "@").map { authority[authority.index(after: $0)...] } ?? authority
        let path = url[url.index(after: colon)...]
        return host + (path.hasPrefix("/") ? "" : "/") + path
    }

    /// Who owns the repository at a URL, which is the first segment of its
    /// path, as in `torvalds` for `git@github.com:torvalds/linux.git`. A local
    /// path has no owner, and neither does a URL with only the repository's
    /// name in its path.
    public static func owner(_ url: String) -> String? {
        let path: Substring
        if let scheme = url.firstRange(of: "://") {
            guard url[..<scheme.lowerBound].lowercased() != "file" else { return nil }
            let rest = url[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            path = rest[slash...]
        } else {
            // A slash before the colon makes it a local path, as in `shown(_:)`.
            guard let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") else { return nil }
            path = url[url.index(after: colon)...]
        }
        let segments = path.split(separator: "/")
        return segments.count >= 2 ? String(segments[0]) : nil
    }

    /// A URL as it compares with another way of writing the same repository's
    /// address: its host and path in lowercase, without `.git` or a slash at
    /// the end, so that `git@github.com:git/git.git` and
    /// `https://github.com/git/git` are the same. Like `shown(_:)`, it leaves
    /// out the user name, and keeps a local path as it is.
    public static func comparable(_ url: String) -> String {
        let trimmed = url.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
        var address = Substring(shown(String(trimmed)).lowercased())
        while address.hasSuffix("/") { address = address.dropLast() }
        if address.hasSuffix(".git") { address = address.dropLast(4) }
        while address.hasSuffix("/") { address = address.dropLast() }
        return String(address)
    }

    /// Who owns a repository with these remotes, each of them once, because
    /// hosts don't care about case. The owner of `origin` comes first, then
    /// the others by the names of their remotes.
    ///
    /// - Parameter urls: Each remote's URL, by the remote's name.
    public static func owners(_ urls: [String: String]) -> [String] {
        let others = urls.keys.filter { $0 != "origin" }.sorted()
        var seen: Set<String> = []
        return (["origin"] + others).compactMap { urls[$0].flatMap(owner) }.filter { seen.insert($0.lowercased()).inserted }
    }
}
