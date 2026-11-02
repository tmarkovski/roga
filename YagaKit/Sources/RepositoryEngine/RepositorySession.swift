import CommitGraph
import GitCore
import GitRunner

/// Everything yaga knows about one repository, and the git processes it
/// keeps running for it.
///
/// For now a session reads history and the text of commits. Refs, worktrees,
/// status, diffs and watching for changes come later, as ARCHITECTURE.md
/// describes.
public actor RepositorySession {
    public nonisolated let location: RepositoryLocation
    public nonisolated let git: Git
    private let catFile: CatFileSession

    public init(location: RepositoryLocation, git: Git) throws {
        self.location = location
        self.git = git
        catFile = try CatFileSession(git: git, directory: location.directory)
    }

    /// Finds the repository that `path` is in and starts a session for it.
    public static func open(containing path: String, git: Git) async throws -> RepositorySession {
        try RepositorySession(location: try await RepositoryLocation.find(containing: path, git: git), git: git)
    }

    /// Loads history in `sort` order. The stream yields the history once its
    /// first `firstRows` rows are in order, and again with every row. Ending
    /// the iteration early, or cancelling its task, stops loading.
    public nonisolated func history(sort: HistoryOrder.Sort, firstRows: Int = 200) -> AsyncThrowingStream<History, any Error> {
        HistoryLoader(git: git, location: location, firstRows: firstRows).load(sort: sort)
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
