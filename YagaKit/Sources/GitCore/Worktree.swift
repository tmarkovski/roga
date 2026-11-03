/// A folder with the repository's files checked out, with its own `HEAD`.
/// A repository has its main worktree, unless it's bare, and any number of
/// linked worktrees that `git worktree add` made.
public struct Worktree: Sendable, Hashable {
    /// The worktree's top folder. A bare repository's entry is its git
    /// directory, which has no files checked out.
    public var path: String
    /// The commit `HEAD` points to, or nil when there's none yet, as in a
    /// repository without commits, or when the entry is a bare repository's.
    public var head: ObjectID?
    /// The full name of the branch checked out, such as `refs/heads/main`, or
    /// nil when `HEAD` is detached or the entry is a bare repository's.
    public var branch: String?
    /// Whether this is the main worktree, which git lists first, rather than
    /// a linked one.
    public var isMain: Bool
    /// Whether this is a bare repository's entry, which has no files checked
    /// out.
    public var isBare: Bool
    /// Whether `git worktree prune` would remove the worktree, which is
    /// almost always because its folder is gone.
    public var isPrunable: Bool
    /// Whether `git worktree lock` keeps it from being removed, which often
    /// means an agent is working in it.
    public var isLocked: Bool

    public init(
        path: String,
        head: ObjectID? = nil,
        branch: String? = nil,
        isMain: Bool = false,
        isBare: Bool = false,
        isPrunable: Bool = false,
        isLocked: Bool = false
    ) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isBare = isBare
        self.isPrunable = isPrunable
        self.isLocked = isLocked
    }
}
