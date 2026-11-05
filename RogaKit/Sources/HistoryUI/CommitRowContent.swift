import CommitGraph
import GitCore

/// What one row of the commit list shows. The short ID is always there, and
/// the rest of the text is nil until it's loaded.
public struct CommitRowContent: Hashable {
    /// A ref shown before the subject.
    public struct Badge: Hashable {
        public enum Kind: Hashable {
            /// The branch `HEAD` points to.
            case currentBranch
            /// `HEAD`, when it isn't on a branch.
            case detachedHead
            case branch
            case remoteBranch
            case tag

            /// Whether this is where `HEAD` is.
            var isCurrent: Bool {
                self == .currentBranch || self == .detachedHead
            }
        }

        public var title: String
        public var kind: Kind
        /// The full name of the ref, which `HEAD` doesn't have when it isn't on
        /// a branch.
        public var refName: String?
        /// The full name of the remote branch that this badge stands for too,
        /// because the branch tracks it and both are on this commit.
        public var upstream: String?
        /// The full names of other remotes' branches that this badge stands for
        /// too, because they have the branch's name and are on this commit.
        public var otherRemoteBranches: [String]

        public init(title: String, kind: Kind, refName: String? = nil, upstream: String? = nil, otherRemoteBranches: [String] = []) {
            self.title = title
            self.kind = kind
            self.refName = refName
            self.upstream = upstream
            self.otherRemoteBranches = otherRemoteBranches
        }

        /// How many clouds the badge has, which is one for each remote it stands
        /// for.
        var cloudCount: Int {
            upstream == nil ? 0 : 1 + otherRemoteBranches.count
        }

        /// Whether double-clicking the badge checks out its branch. There's
        /// nothing to do for the current branch, and a tag isn't a branch.
        public var canCheckOut: Bool {
            switch kind {
            case .branch, .remoteBranch: true
            case .currentBranch, .detachedHead, .tag: false
            }
        }

        /// Whether the row's menu can act on the badge, which is every branch.
        var isBranch: Bool {
            switch kind {
            case .currentBranch, .branch, .remoteBranch: true
            case .detachedHead, .tag: false
            }
        }

        /// A remote's branch shows its own name first and its remote's after it, as
        /// in `tm/fix | origin`, so that it reads like the local branch of that name.
        /// A remote whose name has a slash in it is cut at the slash, which only
        /// changes what's drawn: the tooltip and the menu have the whole name.
        var nameAndRemote: (name: String, remote: String?) {
            guard kind == .remoteBranch, let slash = title.firstIndex(of: "/") else { return (title, nil) }
            return (String(title[title.index(after: slash)...]), String(title[..<slash]))
        }

        /// What the badge's tooltip says, and VoiceOver reads.
        var spokenTitle: String {
            var parts = [title]
            switch kind {
            case .currentBranch: parts.append("current branch")
            case .detachedHead: parts.append("on no branch")
            case .branch, .remoteBranch, .tag: break
            }
            if let upstream {
                let names = ([upstream] + otherRemoteBranches).map(Ref.shortName)
                let list = names.dropLast().joined(separator: ", ")
                parts.append("in sync with " + (list.isEmpty ? names[0] : "\(list) and \(names[names.count - 1])"))
            }
            return parts.joined(separator: ", ")
        }
    }

    public var shortID: String
    public var badges: [Badge]
    public var subject: String?
    /// What follows the subject in the commit's message, on one line.
    public var body: String?
    public var author: String?
    public var date: String?
    /// The graph's lines in this row.
    public var lanes: LaneLayout.Row?
    /// Whether the row stands for a worktree's uncommitted changes rather than
    /// a commit, which its hollow dot shows.
    public var isWorkingTree: Bool
    /// Whether the subject says something's wrong, as it does for a worktree
    /// that has conflicts.
    public var isWarning: Bool
    /// Whether the row is tinted, because a count in the title row would move
    /// the commit.
    public var isPreviewed: Bool

    public init(
        shortID: String,
        badges: [Badge] = [],
        subject: String? = nil,
        body: String? = nil,
        author: String? = nil,
        date: String? = nil,
        lanes: LaneLayout.Row? = nil,
        isWorkingTree: Bool = false,
        isWarning: Bool = false,
        isPreviewed: Bool = false
    ) {
        self.shortID = shortID
        self.badges = badges
        self.subject = subject
        self.body = body
        self.author = author
        self.date = date
        self.lanes = lanes
        self.isWorkingTree = isWorkingTree
        self.isWarning = isWarning
        self.isPreviewed = isPreviewed
    }

    /// Whether the worktree's `HEAD` is on this commit, which a ring around the
    /// dot and bold text show.
    var isCurrent: Bool {
        badges.contains { $0.kind.isCurrent }
    }

    /// The full name of every branch that points to the commit, for the dialog that
    /// the row's menu opens: local ones first, then remote ones from A to Z. That
    /// includes those that share a badge, which stand for a branch each here.
    var branches: [String] {
        let branches = badges.filter(\.isBranch)
        let local = branches.filter { $0.kind != .remoteBranch }
        let remote = branches.filter { $0.kind == .remoteBranch }.compactMap(\.refName)
            + local.flatMap { [$0.upstream].compactMap(\.self) + $0.otherRemoteBranches }
        return local.compactMap(\.refName) + remote.sorted()
    }

    /// Whether the row's menu has anything to offer. git won't delete the current
    /// branch, so a commit with nothing else has nothing to choose from. Only the
    /// dialog can tell about a branch that another worktree has checked out.
    var hasBranchThatCanGo: Bool {
        let current = badges.first { $0.kind == .currentBranch }?.refName
        return branches.contains { $0 != current }
    }

    /// What VoiceOver reads for the row. The body comes last, so that it's easy
    /// to move on from.
    var spokenText: String {
        var parts: [String] = []
        if let subject { parts.append(subject) }
        parts += badges.map(\.spokenTitle)
        if let author { parts.append(author) }
        if let date { parts.append(date) }
        if !shortID.isEmpty { parts.append(shortID) }
        if let body, !body.isEmpty { parts.append(body) }
        return parts.joined(separator: ", ")
    }
}
