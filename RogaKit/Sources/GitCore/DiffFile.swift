/// A file that a diff changes: what `git diff --raw` says about it, and how
/// many of its lines changed.
public struct DiffFile: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case added
        case deleted
        case modified
        /// Moved from `oldPath`. The similarity is how much of the file stayed
        /// the same, from 0 to 100.
        case renamed(similarity: Int)
        /// Copied from `oldPath`, which is still there.
        case copied(similarity: Int)
        /// Changed from one kind of file to another, such as to a symbolic
        /// link.
        case typeChanged
        /// Not in the index, and only in the worktree.
        case untracked
        /// Left with conflicts by a merge that hasn't finished.
        case conflicted
        /// A letter Roga doesn't expect from a diff.
        case other(String)

        /// The letter git uses for the status.
        public var letter: String {
            switch self {
            case .added: "A"
            case .deleted: "D"
            case .modified: "M"
            case .renamed: "R"
            case .copied: "C"
            case .typeChanged: "T"
            case .untracked: "?"
            case .conflicted: "U"
            case .other(let letter): letter
            }
        }
    }

    /// The mode git gives a submodule.
    public static let submoduleMode: UInt32 = 0o160000

    /// How many lines a diff adds to a file and removes from it.
    public struct LineCounts: Sendable, Hashable {
        public var added: Int
        public var removed: Int

        public init(added: Int, removed: Int) {
            self.added = added
            self.removed = removed
        }
    }

    public var status: Status
    /// The file's path from the top of the repository. It's the path after
    /// the change when the file was renamed or copied.
    public var path: String
    /// Where a renamed or copied file came from.
    public var oldPath: String?
    /// The file's mode before and after, such as `0o100644`, which is 0 on the
    /// side where the file doesn't exist.
    public var oldMode: UInt32
    public var newMode: UInt32
    /// The file's object before and after, or nil on the side where the file
    /// doesn't exist.
    public var oldID: ObjectID?
    public var newID: ObjectID?
    /// Nil for a binary file, which has no lines. A submodule has counts of
    /// zero, because the two lines git's patch for one has aren't lines of
    /// any file.
    public var lines: LineCounts?
    /// What's known about the submodule this is beyond its two commits, or nil
    /// for any other file (decision 75).
    public var submodule: SubmoduleChange?

    public init(
        status: Status,
        path: String,
        oldPath: String? = nil,
        oldMode: UInt32,
        newMode: UInt32,
        oldID: ObjectID? = nil,
        newID: ObjectID? = nil,
        lines: LineCounts? = nil,
        submodule: SubmoduleChange? = nil
    ) {
        self.status = status
        self.path = path
        self.oldPath = oldPath
        self.oldMode = oldMode
        self.newMode = newMode
        self.oldID = oldID
        self.newID = newID
        self.lines = lines
        self.submodule = submodule
    }

    /// Whether this is a submodule on either side, which is a commit of
    /// another repository rather than a file.
    public var isSubmodule: Bool {
        oldMode == Self.submoduleMode || newMode == Self.submoduleMode
    }

    /// The part of the path after the last slash.
    public var name: Substring {
        path.lastIndex(of: "/").map { path[path.index(after: $0)...] } ?? path[...]
    }

    /// The part of the path before the last slash, which is empty for a file
    /// at the top of the repository.
    public var folder: Substring {
        path.lastIndex(of: "/").map { path[..<$0] } ?? ""
    }
}
