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

/// How discarding a file takes back its changes (decision 39).
public enum FileDiscard: Sendable, Hashable {
    /// git has a version to go back to, so `git restore` puts that on disk.
    case restore
    /// Its contents are only on disk, so it goes to the Trash, where they stay.
    case trash
}

extension WorktreeChanges.Group {
    /// How discarding a file of this group would go, or nil when it can't be offered.
    ///
    /// - A staged file has no discard, because it would also take any unstaged changes
    ///   to the file, and staging is how someone keeps a version.
    /// - git has nothing to go back to in a conflict, and refuses.
    /// - `git restore` empties a file added with `git add -N` while saying it worked,
    ///   because the index has it with no contents, so that goes to the Trash.
    /// - `git restore` does nothing to a submodule.
    /// - git lists a repository inside the worktree as one untracked folder, ending
    ///   with a slash. It could well be someone's worktree, with its whole history.
    public func discarding(_ file: DiffFile) -> FileDiscard? {
        switch self {
        case .conflicted, .staged:
            return nil
        case .unstaged:
            guard file.oldMode != DiffFile.submoduleMode, file.newMode != DiffFile.submoduleMode else { return nil }
            switch file.status {
            case .modified, .deleted, .typeChanged: return .restore
            case .added: return .trash
            default: return nil
            }
        case .untracked:
            return file.path.hasSuffix("/") ? nil : .trash
        }
    }
}

extension WorktreeChanges {
    /// What stays when everything uncommitted goes, because Roga leaves it alone:
    /// repositories inside the worktree, and submodules.
    public var stayingWhenDiscardingEverything: [DiffFile] {
        (unstaged.filter { Group.unstaged.discarding($0) == nil } + untracked.filter { Group.untracked.discarding($0) == nil })
            .sorted { $0.path < $1.path }
    }

    /// What has to go to the Trash when everything uncommitted goes, because git has
    /// no copy of it to keep.
    public var trashedWhenDiscardingEverything: [DiffFile] {
        (unstaged.filter { Group.unstaged.discarding($0) == .trash } + untracked.filter { Group.untracked.discarding($0) == .trash })
            .sorted { $0.path < $1.path }
    }
}
