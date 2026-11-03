/// What's uncommitted in a worktree: the files that `git status` lists, in the
/// groups the commit panel shows them in. A file with both staged and unstaged
/// changes is in both groups, since each of those is a diff of its own. Its
/// files have line counts of zero until something counts them.
public struct WorktreeChanges: Sendable, Hashable {
    public enum Group: Sendable, Hashable, CaseIterable {
        case conflicted
        case unstaged
        case untracked
        case staged
    }

    /// The commit `HEAD` points to, or nil when there's none yet.
    public var head: ObjectID?
    /// How many files have uncommitted changes, counting each one once.
    public var fileCount: Int
    public var conflicted: [DiffFile]
    public var unstaged: [DiffFile]
    public var untracked: [DiffFile]
    public var staged: [DiffFile]
    /// The files and folders git ignores, when `git status` was asked for them.
    /// They aren't uncommitted changes, so `fileCount` leaves them out.
    public var ignored: [String]

    public init(
        head: ObjectID? = nil,
        fileCount: Int = 0,
        conflicted: [DiffFile] = [],
        unstaged: [DiffFile] = [],
        untracked: [DiffFile] = [],
        staged: [DiffFile] = [],
        ignored: [String] = []
    ) {
        self.head = head
        self.fileCount = fileCount
        self.conflicted = conflicted
        self.unstaged = unstaged
        self.untracked = untracked
        self.staged = staged
        self.ignored = ignored
    }

    public subscript(group: Group) -> [DiffFile] {
        switch group {
        case .conflicted: conflicted
        case .unstaged: unstaged
        case .untracked: untracked
        case .staged: staged
        }
    }
}
