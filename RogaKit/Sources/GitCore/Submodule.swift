/// One of a worktree's submodules, as the refs panel lists it (decision 75):
/// where the worktree has it, the commit the worktree records for it, and how
/// the copy checked out there stands against that.
///
/// All of it belongs to the worktree rather than the repository, because each
/// linked worktree has its own index and its own checkouts.
public struct Submodule: Sendable, Hashable {
    /// What `.gitmodules` calls it, which is usually its path.
    public var name: String
    /// Where the worktree has it, from the top of the worktree.
    public var path: String
    /// Where it's from, in the form that `RemoteAddress.shown(_:)` gives, which
    /// leaves out a user name and password, or nil when nothing says.
    public var address: String?
    /// The commit that the worktree's index records for the path.
    public var recorded: ObjectID
    /// The commit that's checked out in the worktree, or nil when the submodule
    /// isn't checked out there.
    public var checkedOut: ObjectID?
    /// How the checkout stands against what's recorded, as its row under
    /// Unstaged would say: whether it's on another commit, how far apart the
    /// two are, and how many uncommitted files it has. Its `distance` is nil
    /// until the submodule's own repository has been read, which happens after
    /// the list shows.
    public var change: SubmoduleChange

    public init(name: String, path: String, address: String? = nil, recorded: ObjectID, checkedOut: ObjectID?, change: SubmoduleChange? = nil) {
        self.name = name
        self.path = path
        self.address = address
        self.recorded = recorded
        self.checkedOut = checkedOut
        self.change = change ?? Self.unread(recorded: recorded, checkedOut: checkedOut)
    }

    /// What's known from the two commits alone, before anything has read the
    /// submodule's own repository. One that isn't checked out has nothing more
    /// to read.
    public static func unread(recorded: ObjectID, checkedOut: ObjectID?) -> SubmoduleChange {
        guard let checkedOut else { return SubmoduleChange(checkout: [], distance: .notCheckedOut) }
        return SubmoduleChange(checkout: checkedOut == recorded ? [] : [.commitChanged])
    }

    /// Whether the submodule's own repository has been read, or has none to
    /// read.
    public var isRead: Bool {
        change.distance != nil
    }

    /// The row the submodule has under Unstaged when its checkout differs from
    /// what's recorded, made the same way when it doesn't. The panels show a
    /// listed submodule through it, so that they say and offer exactly what
    /// they do for that row.
    public var file: DiffFile {
        DiffFile(
            status: .modified,
            path: path,
            oldMode: DiffFile.submoduleMode,
            newMode: DiffFile.submoduleMode,
            oldID: recorded,
            lines: DiffFile.LineCounts(added: 0, removed: 0),
            submodule: change
        )
    }
}
