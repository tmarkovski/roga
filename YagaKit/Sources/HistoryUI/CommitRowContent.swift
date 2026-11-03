import CommitGraph

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

        public init(title: String, kind: Kind, refName: String? = nil) {
            self.title = title
            self.kind = kind
            self.refName = refName
        }

        /// Whether double-clicking the badge checks out its branch. There's
        /// nothing to do for the current branch, and a tag isn't a branch.
        var canCheckOut: Bool {
            switch kind {
            case .branch, .remoteBranch: true
            case .currentBranch, .detachedHead, .tag: false
            }
        }

        /// Whether the row's menu lists the badge, which is every branch.
        var isBranch: Bool {
            switch kind {
            case .currentBranch, .branch, .remoteBranch: true
            case .detachedHead, .tag: false
            }
        }
    }

    public var shortID: String
    public var badges: [Badge]
    public var subject: String?
    public var author: String?
    public var date: String?
    /// The graph's lines in this row.
    public var lanes: LaneLayout.Row?
    /// Whether the row stands for a worktree's uncommitted changes rather than
    /// a commit, which its hollow dot shows.
    public var isWorkingTree: Bool
    /// Whether the row is tinted, because a count in the title row would move
    /// the commit.
    public var isPreviewed: Bool

    public init(
        shortID: String,
        badges: [Badge] = [],
        subject: String? = nil,
        author: String? = nil,
        date: String? = nil,
        lanes: LaneLayout.Row? = nil,
        isWorkingTree: Bool = false,
        isPreviewed: Bool = false
    ) {
        self.shortID = shortID
        self.badges = badges
        self.subject = subject
        self.author = author
        self.date = date
        self.lanes = lanes
        self.isWorkingTree = isWorkingTree
        self.isPreviewed = isPreviewed
    }

    /// Whether the worktree's `HEAD` is on this commit, which a ring around the
    /// dot and bold text show.
    var isCurrent: Bool {
        badges.contains { $0.kind.isCurrent }
    }

    /// What VoiceOver reads for the row.
    var spokenText: String {
        var parts: [String] = []
        if let subject { parts.append(subject) }
        parts += badges.map { $0.kind == .currentBranch ? "\($0.title), current branch" : $0.title }
        if let author { parts.append(author) }
        if let date { parts.append(date) }
        if !shortID.isEmpty { parts.append(shortID) }
        return parts.joined(separator: ", ")
    }
}
