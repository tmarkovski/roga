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
        }

        public var title: String
        public var kind: Kind

        public init(title: String, kind: Kind) {
            self.title = title
            self.kind = kind
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

    public init(
        shortID: String,
        badges: [Badge] = [],
        subject: String? = nil,
        author: String? = nil,
        date: String? = nil,
        lanes: LaneLayout.Row? = nil,
        isWorkingTree: Bool = false
    ) {
        self.shortID = shortID
        self.badges = badges
        self.subject = subject
        self.author = author
        self.date = date
        self.lanes = lanes
        self.isWorkingTree = isWorkingTree
    }

    /// What VoiceOver reads for the row.
    var spokenText: String {
        var parts: [String] = []
        if let subject { parts.append(subject) }
        parts += badges.map(\.title)
        if let author { parts.append(author) }
        if let date { parts.append(date) }
        if !shortID.isEmpty { parts.append(shortID) }
        return parts.joined(separator: ", ")
    }
}
