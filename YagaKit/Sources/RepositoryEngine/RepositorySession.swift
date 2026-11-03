import CommitGraph
import Foundation
import GitCore
import GitRunner

/// Everything yaga knows about one repository, and the git processes it
/// keeps running for it. All of the repository's worktrees share it.
///
/// For now a session lists worktrees and refs, reads history, the text of
/// commits, the files they changed and their patches, reads what's uncommitted
/// in a worktree, checks out branches, fetches, pulls and pushes, and keeps the
/// commit-graph files up to date. Watching for changes comes later, as
/// ARCHITECTURE.md describes.
public actor RepositorySession {
    public nonisolated let location: RepositoryLocation
    public nonisolated let git: Git
    private nonisolated let catFile: CatFileSession
    private var commitGraphUpdate: Task<CommitGraphUpdate, any Error>?
    /// The running fetch. There's only ever one, because every worktree shares
    /// the repository's remote branches.
    private var runningFetch: Task<(any Error)?, Never>?
    /// When the last quiet fetch started.
    private var lastQuietFetch: ContinuousClock.Instant?
    /// What became of the last fetch.
    private var fetchRecord: FetchRecord?

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

    /// Lists every branch, remote, tag and stash, with what the refs panel says
    /// about each, including the subject of the commit each tag points to.
    ///
    /// - Parameter worktree: The folder of the worktree whose current branch
    ///   to read.
    public nonisolated func refDetails(in worktree: String) async throws -> RefDetails {
        var details = try await RefDetailsLoader.load(git: git, in: worktree, worktrees: try await worktrees())
        // Reading them in pieces leaves room for the commit list to read the
        // text of its rows in between, in a repository with very many tags.
        let tagged = details.tags.indices.filter { details.tags[$0].commit != nil }
        for start in stride(from: 0, to: tagged.count, by: 1000) {
            let indices = tagged[start..<min(start + 1000, tagged.count)]
            let commits = try await commits(indices.compactMap { details.tags[$0].commit })
            for (index, commit) in zip(indices, commits) {
                details.tags[index].subject = commit?.subject
            }
        }
        return details
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

    /// Who owns the repository, from its remotes' URLs, with `origin`'s owner
    /// first.
    public nonisolated func owners() async throws -> [String] {
        try await LocalClones.owners(in: location.commonDirectory, git: git)
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

    /// Lists the files a commit changed, with the lines added and removed in
    /// each. A merge is compared with its first parent.
    public nonisolated func changedFiles(in commit: ObjectID) async throws -> [DiffFile] {
        try await DiffLoader.changedFiles(in: commit, git: git, directory: location.commonDirectory)
    }

    /// Reads what a commit changed in one of its files, which is the slower
    /// half of showing a commit, so it waits until someone looks at the file.
    ///
    /// - Throws: `RepositoryError.patchTooLarge` for a patch too long to show.
    public nonisolated func patch(of file: DiffFile, in commit: ObjectID) async throws -> FilePatch {
        try await DiffLoader.patch(of: file, in: commit, git: git, directory: location.commonDirectory)
    }

    /// Lists a worktree's uncommitted files, without their line counts, which
    /// is enough for saying how many there are.
    ///
    /// - Parameters:
    ///   - worktree: The worktree's folder.
    ///   - isUpkeep: Whether nobody is waiting for the answer, which runs git
    ///     at low priority.
    /// - Throws: `RepositoryError.tooManyChanges` for a list too long to read.
    public nonisolated func status(in worktree: String, isUpkeep: Bool = false) async throws -> WorktreeChanges {
        try await ChangesLoader.status(in: worktree, git: git, isUpkeep: isUpkeep)
    }

    /// Lists a worktree's uncommitted files, with the lines added and removed
    /// in each that's in the index. It takes longer than `status`, so it waits
    /// until someone looks at the files.
    ///
    /// - Parameter worktree: The worktree's folder.
    public nonisolated func changes(in worktree: String) async throws -> WorktreeChanges {
        try await ChangesLoader.changes(in: worktree, format: location.format, git: git)
    }

    /// Reads the patch of a file from a commit or a worktree.
    ///
    /// - Throws: `RepositoryError.patchTooLarge` for a patch too long to show.
    public nonisolated func patch(of file: DiffFile, from source: PatchSource) async throws -> FilePatch {
        switch source {
        case .commit(let commit):
            try await patch(of: file, in: commit)
        case .worktree(let path, let group, let head):
            try await ChangesLoader.patch(of: file, in: group, head: head, directory: path, format: location.format, git: git)
        }
    }

    /// Puts a worktree on a branch, or on the local branch for a remote branch.
    /// git refuses when the worktree's uncommitted changes would be overwritten,
    /// and they stay as they were.
    ///
    /// Cancelling this stops git, which may be partway through writing files, so
    /// it's best left to finish.
    ///
    /// - Parameters:
    ///   - name: The full name of the branch or remote branch.
    ///   - worktree: The worktree's folder.
    /// - Throws: `GitError` when git refuses, which says why.
    public nonisolated func checkOut(ref name: String, in worktree: String) async throws -> BranchCheckout {
        try await BranchCheckout.run(ref: name, in: worktree, worktrees: try await worktrees(), git: git)
    }

    /// Says where a worktree's branch stands against its upstream, or nil when
    /// it isn't on a branch, or its branch has no commits yet.
    public nonisolated func branchStatus(in worktree: String) async throws -> BranchStatus? {
        try await BranchStatusLoader.load(git: git, in: worktree)
    }

    /// Lists the commits that `tip` has and `base` doesn't, newest first.
    ///
    /// - Parameters:
    ///   - base: The full name of a ref, or `HEAD`.
    ///   - tip: The full name of a ref, or `HEAD`.
    ///   - limit: The most to list.
    ///   - worktree: The worktree whose `HEAD` to use.
    public nonisolated func commits(from base: String, to tip: String, limit: Int, in worktree: String) async throws -> [ObjectID] {
        let command = GitCommand("rev-list", "--max-count=\(limit)", "\(base)..\(tip)", "--", in: worktree)
        return try await git.text(command).split(separator: "\n").compactMap { ObjectID(hex: String($0)) }
    }

    /// Fetches by itself, without asking anyone, as long as this repository
    /// hasn't done that within `minimumInterval`, and returns what became of the
    /// latest fetch (decision 20). A fetch that's running already is waited for.
    /// It doesn't throw, because nobody asked for it, so the record has what git
    /// said.
    ///
    /// - Parameter timeLimit: How long it can run before yaga stops it, because
    ///   a stalled connection would otherwise hold up every later fetch.
    public func fetchQuietly(
        from remote: String,
        minimumInterval: Duration = .seconds(60),
        timeLimit: Duration = .seconds(60)
    ) async -> FetchRecord {
        if let runningFetch {
            _ = await runningFetch.value
            return lastFetch()
        }
        if let lastQuietFetch, ContinuousClock.now - lastQuietFetch < minimumInterval { return lastFetch() }
        lastQuietFetch = .now
        let git = git
        let command = RemoteCommands.quietFetch(from: remote, in: location.commonDirectory)
        await runFetch { () async throws(any Error) in
            try await withThrowingTaskGroup { group in
                group.addTask { _ = try await git.run(command) }
                group.addTask {
                    try await Task.sleep(for: timeLimit)
                    throw RepositoryError.fetchTookTooLong
                }
                try await group.next()
                group.cancelAll()
            }
        }
        return lastFetch()
    }

    /// Fetches because someone asked to, whenever yaga last did.
    ///
    /// - Throws: `GitError` when git can't fetch, which says why.
    public func fetch(from remote: String, in worktree: String) async throws {
        _ = await runningFetch?.value
        let git = git
        let command = RemoteCommands.asked(["fetch", remote], in: worktree)
        lastQuietFetch = .now
        if let error = await runFetch({ () async throws(any Error) in _ = try await git.run(command) }) {
            throw error
        }
    }

    /// Runs a fetch as the running one, records what became of it, and returns
    /// the error if it failed.
    @discardableResult
    private func runFetch(_ fetch: sending @escaping () async throws(any Error) -> Void) async -> (any Error)? {
        let task = Task(priority: .utility) { () -> (any Error)? in
            do {
                try await fetch()
                return nil
            } catch {
                return error
            }
        }
        runningFetch = task
        let failure = await task.value
        runningFetch = nil
        switch failure {
        case nil:
            fetchRecord = FetchRecord(lastFetched: Date())
        case is CancellationError:
            // The session is closing, so nobody will read the record.
            break
        case let failure?:
            fetchRecord = FetchRecord(lastFetched: lastFetch().lastFetched, failure: (failure as? GitError)?.message ?? String(describing: failure))
        }
        return failure
    }

    /// What became of the last fetch. Before yaga has fetched, the date of
    /// `FETCH_HEAD` says when someone else last did.
    public func lastFetch() -> FetchRecord {
        if let fetchRecord { return fetchRecord }
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.commonDirectory + "/FETCH_HEAD")
        return FetchRecord(lastFetched: attributes?[.modificationDate] as? Date)
    }

    /// Pulls a worktree's branch, once any fetch that's running has finished.
    /// Like a checkout, this is best left to finish.
    ///
    /// - Throws: `GitError` when git refuses or hits a conflict, which says why.
    public func pull(_ pull: Pull, in worktree: String) async throws {
        _ = await runningFetch?.value
        _ = try await Self.run(pull.arguments, in: worktree, git: git)
    }

    /// Pushes a worktree's branch, once any fetch that's running has finished.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    public func push(_ push: Push, in worktree: String) async throws {
        _ = await runningFetch?.value
        _ = try await Self.run(push.arguments, in: worktree, git: git)
    }

    /// Says whether a worktree is partway through a merge or a rebase.
    public nonisolated func stoppedPull(in worktree: String) async throws -> StoppedPull? {
        try await RemoteCommands.stoppedPull(in: worktree, git: git)
    }

    /// Goes back to before a pull that stopped partway.
    public nonisolated func undo(_ pull: StoppedPull, in worktree: String) async throws {
        _ = try await Self.run(pull.abortArguments, in: worktree, git: git)
    }

    /// Makes a new branch on the commit a worktree is on, and switches to it
    /// there or in a new worktree.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    public nonisolated func create(_ branch: NewBranch, in worktree: String) async throws {
        _ = try await Self.run(branch.arguments, in: worktree, git: git)
    }

    private nonisolated static func run(_ arguments: [String], in worktree: String, git: Git) async throws -> GitResult {
        try await git.run(RemoteCommands.asked(arguments, in: worktree))
    }

    /// Writes what the repository's commit-graph files are missing, at low
    /// priority (decision 6). History reads the files when it loads, so the
    /// next load is the one that gets faster.
    ///
    /// Only one update runs at a time, and a call during one waits for it.
    /// Cancelling the caller doesn't stop the update, but closing the session
    /// does.
    ///
    /// - Throws: `GitError` when git can't write the files, which is often
    ///   because another git process is writing them.
    public func updateCommitGraph() async throws -> CommitGraphUpdate {
        if let running = commitGraphUpdate { return try await running.value }
        let upkeep = CommitGraphUpkeep(git: git, location: location, catFile: catFile)
        let update = Task(priority: .background) { try await upkeep.update() }
        commitGraphUpdate = update
        defer { commitGraphUpdate = nil }
        return try await update.value
    }

    /// Ends the session's git processes. Dropping the session does the same,
    /// except that an update of the commit-graph files runs to its end.
    public func close() {
        commitGraphUpdate?.cancel()
        runningFetch?.cancel()
        catFile.close()
    }
}

/// Where a file's changes are, which says how to read its patch.
public enum PatchSource: Sendable, Hashable {
    case commit(ObjectID)
    /// A group of a worktree's uncommitted files. `head` is the commit that
    /// the worktree's staged changes compare with, or nil when there's none yet.
    case worktree(path: String, group: WorktreeChanges.Group, head: ObjectID?)
}
