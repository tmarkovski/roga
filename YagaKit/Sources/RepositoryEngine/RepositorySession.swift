import CommitGraph
import GitCore
import GitRunner

/// Everything yaga knows about one repository, and the git processes it
/// keeps running for it. All of the repository's worktrees share it.
///
/// For now a session lists worktrees and reads history and the text of
/// commits. Status, diffs and watching for changes come later, as
/// ARCHITECTURE.md describes.
public actor RepositorySession {
    public nonisolated let location: RepositoryLocation
    public nonisolated let git: Git
    private nonisolated let catFile: CatFileSession

    public init(location: RepositoryLocation, git: Git) throws {
        self.location = location
        self.git = git
        // The session belongs to the repository rather than to the worktree
        // it was found from, so it runs git in the git directory that every
        // worktree shares.
        catFile = try CatFileSession(git: git, directory: location.commonDirectory)
    }

    /// Finds the repository that `path` is in and starts a session for it.
    public static func open(containing path: String, git: Git) async throws -> RepositorySession {
        try RepositorySession(location: try await RepositoryLocation.find(containing: path, git: git), git: git)
    }

    /// Loads history in `sort` order. The stream yields the history once its
    /// first `firstRows` rows are laid out, and again with every row. Ending
    /// the iteration early, or cancelling its task, stops loading.
    ///
    /// - Parameter worktree: The folder of the worktree whose `HEAD` history
    ///   starts from, or nil for the one the session was opened from.
    public nonisolated func history(
        in worktree: String? = nil,
        sort: HistoryOrder.Sort,
        firstRows: Int = 100
    ) -> AsyncThrowingStream<History, any Error> {
        HistoryLoader(git: git, location: location, directory: worktree ?? location.directory, catFile: catFile, firstRows: firstRows)
            .load(sort: sort)
    }

    /// Lists every ref, and the commit the worktree's `HEAD` points to.
    ///
    /// - Parameter worktree: The worktree's folder, or nil for the one the
    ///   session was opened from.
    public nonisolated func refs(in worktree: String? = nil) async throws -> RefList {
        try await RefsLoader.load(git: git, in: worktree ?? location.directory)
    }

    /// Lists the main worktree first, then the linked ones in the order of
    /// their names.
    public nonisolated func worktrees() async throws -> [Worktree] {
        let command = GitCommand(WorktreeListParser.arguments, in: location.commonDirectory)
        do {
            return try WorktreeListParser.parse(try await git.run(command).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    /// Reads commits with the session's `git cat-file`. The result has an
    /// entry for each ID, which is nil when the repository has no such
    /// commit.
    public func commits(_ ids: [ObjectID]) async throws -> [CommitInfo?] {
        let objects = try await catFile.objects(ids.map(\.hex))
        return zip(ids, objects).map { id, object in
            guard let object, object.type == .commit else { return nil }
            return try? CommitParser.parse(object.contents, id: id)
        }
    }

    /// Ends the session's git processes. Dropping the session does the same.
    public func close() {
        catFile.close()
    }
}
