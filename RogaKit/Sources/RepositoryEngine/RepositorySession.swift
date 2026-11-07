import CommitGraph
import Foundation
import GitCore
import GitRunner

/// Everything Roga knows about one repository, and the git processes it
/// keeps running for it. All of the repository's worktrees share it.
///
/// For now a session lists worktrees and refs, reads history, the text of
/// commits, the files they changed and their patches, reads what's uncommitted
/// in a worktree, checks out and deletes branches, goes to commits, deletes linked worktrees
/// and mends them when their folders move, fetches, pulls and pushes, keeps the
/// commit-graph files up to date, and watches the repository for changes on disk.
public actor RepositorySession {
    public nonisolated let location: RepositoryLocation
    public nonisolated let git: Git
    /// Where discarded files go that git has no copy of.
    public nonisolated let trash: FileTrash
    private nonisolated let catFile: CatFileSession
    private nonisolated let watcher: RepositoryWatcher
    /// The latest `git status` in each worktree that more than one look can
    /// share, by the worktree's folder.
    private var statusRuns: [String: StatusRun] = [:]
    private var commitGraphUpdate: Task<CommitGraphUpdate, any Error>?
    /// The running fetch. There's only ever one, because every worktree shares
    /// the repository's remote branches.
    private var runningFetch: Task<(any Error)?, Never>?
    /// Whether Roga started the running fetch by itself, so nobody needs it.
    private var runningFetchIsQuiet = false
    /// When the last quiet fetch started.
    private var lastQuietFetch: ContinuousClock.Instant?
    /// What became of the last fetch.
    private var fetchRecord: FetchRecord?

    public init(location: RepositoryLocation, git: Git, trash: FileTrash = .system) throws {
        self.location = location
        self.git = git
        self.trash = trash
        // The session belongs to the repository rather than to the worktree
        // it was found from, so it runs git in the git directory that every
        // worktree shares.
        catFile = try CatFileSession(git: git, directory: location.commonDirectory)
        watcher = RepositoryWatcher(git: git)
    }

    /// Finds the repository that `path` is in and starts a session for it.
    public static func open(containing path: String, git: Git, trash: FileTrash = .system) async throws -> RepositorySession {
        try await start(location: try await RepositoryLocation.find(containing: path, git: git), git: git, trash: trash)
    }

    /// Starts a session away from the caller's actor, because that starts git.
    @concurrent
    public static func start(location: RepositoryLocation, git: Git, trash: FileTrash = .system) async throws -> RepositorySession {
        try RepositorySession(location: location, git: git, trash: trash)
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
    @concurrent
    public nonisolated func refs(in worktree: String? = nil) async throws -> RefList {
        try await RefsLoader.load(git: git, in: worktree ?? location.directory)
    }

    /// Lists every branch, remote, tag and stash, with what the refs panel says
    /// about each, including the subject of the commit each tag points to.
    ///
    /// - Parameter worktree: The folder of the worktree whose current branch
    ///   to read.
    @concurrent
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
    @concurrent
    public nonisolated func worktrees() async throws -> [Worktree] {
        let command = GitCommand(WorktreeListParser.arguments, in: location.commonDirectory)
        do {
            return try WorktreeListParser.parse(try await git.run(command).output)
        } catch let error as ParseError {
            throw RepositoryError.unexpectedOutput(command, error.description)
        }
    }

    /// Mends the links between the repository and a linked worktree that moved to
    /// `folder`, or without a folder, every linked worktree that's still where git
    /// last saw it, after the main worktree moved (`WorktreeRepair`).
    ///
    /// - Throws: `GitError` when git can't, as when the folder isn't a linked
    ///   worktree. A folder that's another of the repository's worktrees mends
    ///   nothing and doesn't throw.
    @concurrent
    public nonisolated func repairWorktrees(movedTo folder: String? = nil) async throws {
        _ = try await Self.run(WorktreeRepair.arguments(movedTo: folder), in: location.commonDirectory, git: git)
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

    /// Lists the files that differ from one commit to another, with the lines
    /// added and removed in each.
    ///
    /// - Parameter from: The commit to compare from, or nil for nothing at all,
    ///   which lists every file in `to` as added.
    public nonisolated func changedFiles(from: ObjectID?, to: ObjectID) async throws -> [DiffFile] {
        try await DiffLoader.changedFiles(from: from, to: to, format: location.format, git: git, directory: location.commonDirectory)
    }

    /// Reads what a stash holds, from its commit.
    ///
    /// - Throws: `RepositoryError.notAStash` for a commit that isn't one.
    public func stashContents(_ stash: ObjectID) async throws -> StashContents {
        guard let commit = try await commits([stash]).first ?? nil else { throw RepositoryError.notAStash(stash) }
        return try await StashContents.load(
            stash: stash, parents: commit.parents, format: location.format, git: git, directory: location.commonDirectory
        )
    }

    /// Reads a branch's commits since it left the branches it's compared with, by
    /// their full names, and where it left them.
    ///
    /// - Parameter limit: The most commits to list.
    /// - Throws: `RepositoryError.noSuchRef` when the branch isn't there any more.
    @concurrent
    public nonisolated func review(branch: String, against others: [String], limit: Int = 10_000) async throws -> BranchReview {
        try await BranchReview.load(branch: branch, against: others, limit: limit, git: git, directory: location.commonDirectory)
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

    /// A `git status` that more than one look can share.
    private struct StatusRun {
        /// The number of the latest change the watcher had seen when it started.
        var asNewAs: Int
        var task: Task<WorktreeChanges, any Error>
    }

    /// Lists a worktree's uncommitted files as they were after a change on disk,
    /// sharing a `git status` that started after the watcher saw that change.
    /// When the sidebar and a window both look at a worktree because of the
    /// same change, git runs once.
    ///
    /// Cancelling the caller doesn't stop git, because someone else may be
    /// waiting for it.
    ///
    /// - Parameters:
    ///   - worktree: The worktree's folder.
    ///   - isUpkeep: Whether nobody is waiting for the answer, which runs git
    ///     at low priority if it has to run.
    ///   - change: The `RepositoryChanges.number` of the change.
    /// - Throws: `RepositoryError.tooManyChanges` for a list too long to read.
    public func status(in worktree: String, isUpkeep: Bool = false, asNewAs change: Int) async throws -> WorktreeChanges {
        if let run = statusRuns[worktree], run.asNewAs >= change {
            return try await run.task.value
        }
        let task = Task.detached { [git] in
            try await ChangesLoader.status(in: worktree, git: git, isUpkeep: isUpkeep)
        }
        statusRuns[worktree] = StatusRun(asNewAs: watcher.latestChange, task: task)
        do {
            return try await task.value
        } catch {
            if statusRuns[worktree]?.task == task { statusRuns[worktree] = nil }
            throw error
        }
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
        case .commits(let from, let to, _):
            try await DiffLoader.patch(of: file, from: from, to: to, format: location.format, git: git, directory: location.commonDirectory)
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
    @concurrent
    public nonisolated func checkOut(ref name: String, in worktree: String) async throws -> BranchCheckout {
        try await BranchCheckout.run(ref: name, in: worktree, worktrees: try await worktrees(), git: git)
    }

    /// Finds out what going to a commit would come to, without changing anything.
    ///
    /// - Parameters:
    ///   - commit: The commit to go to.
    ///   - limit: The most commits to list of those it would lose.
    ///   - worktree: The worktree's folder.
    @concurrent
    public nonisolated func prepareToSwitch(to commit: ObjectID, limit: Int, in worktree: String) async throws -> CommitSwitch {
        try await CommitSwitch.prepare(to: commit, limit: limit, in: worktree, worktrees: try await worktrees(), git: git)
    }

    /// Goes to a commit. git refuses when the worktree's uncommitted changes are in
    /// the way, and nothing changes. Like a checkout, this is best left to finish.
    ///
    /// - Throws: `CommitSwitch.Outdated` when something else has moved `HEAD` since
    ///   this was worked out, or `GitError` when git refuses, which says why.
    @concurrent
    public nonisolated func run(_ commitSwitch: CommitSwitch, in worktree: String) async throws {
        try await commitSwitch.run(in: worktree, git: git)
    }

    /// Says where a worktree's branch stands against its upstream, or nil when
    /// it isn't on a branch, or its branch has no commits yet.
    public nonisolated func branchStatus(in worktree: String) async throws -> BranchStatus? {
        try await BranchStatusLoader.load(git: git, in: worktree)
    }

    /// Says how far each of several branches is from its upstream, with one git
    /// at utility priority, for when nobody waits for the answer.
    ///
    /// - Parameters:
    ///   - branches: Their full names.
    ///   - worktree: Any of the repository's worktrees.
    /// - Returns: The counts by branch, for the branches that have an upstream
    ///   or had one that's gone.
    public nonisolated func upstreams(of branches: [String], in worktree: String) async throws -> [String: UpstreamCounts] {
        try await BranchStatusLoader.upstreams(of: branches, git: git, in: worktree)
    }

    /// Lists the commits that `tip` has and `base` doesn't, newest first.
    ///
    /// - Parameters:
    ///   - base: The full name of a ref, or `HEAD`.
    ///   - tip: The full name of a ref, or `HEAD`.
    ///   - limit: The most to list.
    ///   - worktree: The worktree whose `HEAD` to use.
    @concurrent
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
    /// - Parameter timeLimit: How long it can run before Roga stops it, because
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
        await runFetch(isQuiet: true) { () async throws(any Error) in
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

    /// What a fetch someone asks for runs, by its arguments after `git`, which the
    /// Fetch button's tooltip shows.
    public nonisolated static func fetchArguments(from remote: String) -> [String] {
        ["fetch", remote]
    }

    /// Fetches because someone asked to, whenever Roga last did.
    ///
    /// - Throws: `GitError` when git can't fetch, which says why.
    public func fetch(from remote: String, in worktree: String) async throws {
        await clearTheWayForSomeone()
        let git = git
        let command = RemoteCommands.asked(Self.fetchArguments(from: remote), in: worktree)
        lastQuietFetch = .now
        if let error = await runFetch(isQuiet: false, { () async throws(any Error) in _ = try await git.run(command) }) {
            throw error
        }
    }

    /// Clears the way for something someone asked for, which can't run alongside
    /// a fetch. A fetch that Roga started by itself is stopped, since nobody is
    /// waiting for it and it may be on a slow connection, and it can run again as
    /// soon as Roga next has a reason to fetch. One that someone asked for runs to
    /// its end.
    private func clearTheWayForSomeone() async {
        guard let runningFetch else { return }
        if runningFetchIsQuiet {
            runningFetch.cancel()
            lastQuietFetch = nil
        }
        _ = await runningFetch.value
    }

    /// Runs a fetch as the running one, records what became of it, and returns
    /// the error if it failed.
    @discardableResult
    private func runFetch(isQuiet: Bool, _ fetch: sending @escaping () async throws(any Error) -> Void) async -> (any Error)? {
        let task = Task(priority: .utility) { () -> (any Error)? in
            do {
                try await fetch()
                return nil
            } catch {
                return error
            }
        }
        runningFetch = task
        runningFetchIsQuiet = isQuiet
        let failure = await task.value
        runningFetch = nil
        runningFetchIsQuiet = false
        switch failure {
        case nil:
            fetchRecord = FetchRecord(lastFetched: Date())
        case is CancellationError:
            // The session is closing, or a quiet fetch made way for something
            // someone asked for. Neither says anything about the remote.
            break
        case let failure?:
            fetchRecord = FetchRecord(lastFetched: lastFetch().lastFetched, failure: (failure as? GitError)?.message ?? String(describing: failure))
        }
        return failure
    }

    /// What became of the last fetch. Before Roga has fetched, the date of
    /// `FETCH_HEAD` says when someone else last did.
    public func lastFetch() -> FetchRecord {
        if let fetchRecord { return fetchRecord }
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.commonDirectory + "/FETCH_HEAD")
        return FetchRecord(lastFetched: attributes?[.modificationDate] as? Date)
    }

    /// Pulls a worktree's branch, once any fetch that's running has stopped.
    /// Like a checkout, this is best left to finish.
    ///
    /// - Throws: `GitError` when git refuses or hits a conflict, which says why.
    public func pull(_ pull: Pull, in worktree: String) async throws {
        await clearTheWayForSomeone()
        _ = try await Self.run(pull.arguments, in: worktree, git: git)
    }

    /// Makes this the way the repository pulls from now on, in its own git config,
    /// because someone asked Roga to remember that (decision 29).
    ///
    /// - Throws: `GitError` when git can't write the config, which says why.
    @concurrent
    public nonisolated func remember(_ pull: Pull, in worktree: String) async throws {
        guard let arguments = pull.rememberArguments else { return }
        _ = try await Self.run(arguments, in: worktree, git: git)
    }

    /// Pushes a worktree's branch, once any fetch that's running has stopped.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    public func push(_ push: Push, in worktree: String) async throws {
        await clearTheWayForSomeone()
        _ = try await Self.run(push.arguments, in: worktree, git: git)
    }

    /// Finds out what deleting a branch would come to, without changing anything.
    ///
    /// - Parameters:
    ///   - name: The full name of the branch or remote branch.
    ///   - limit: The most commits to list of those it would lose.
    ///   - worktree: The worktree's folder.
    @concurrent
    public nonisolated func prepareToDelete(ref name: String, limit: Int, in worktree: String) async throws -> BranchDeletion {
        try await BranchDeletion.prepare(ref: name, limit: limit, in: worktree, worktrees: try await worktrees(), git: git)
    }

    /// Finds out what deleting some of the branches on a commit would come to,
    /// without changing anything.
    ///
    /// - Parameters:
    ///   - names: The full names of the branches and remote branches on the commit.
    ///   - commit: The commit they were on when someone asked.
    ///   - limit: The most commits to list of those deleting all of them would lose.
    ///   - worktree: The worktree's folder.
    @concurrent
    public nonisolated func prepareToDelete(branches names: [String], on commit: ObjectID, limit: Int, in worktree: String) async throws -> CommitBranchesDeletion {
        try await CommitBranchesDeletion.prepare(branches: names, on: commit, limit: limit, in: worktree, worktrees: try await worktrees(), git: git)
    }

    /// Deletes a branch. Deleting one from a remote first stops any fetch that's
    /// running, because that fetch could bring the branch's copy back.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    public func delete(_ deletion: BranchDeletion, in worktree: String) async throws {
        if case .remote = deletion.place { await clearTheWayForSomeone() }
        try await deletion.run(in: worktree, git: git)
    }

    /// Finds out what each way of deleting a linked worktree would come to, without
    /// changing anything.
    ///
    /// - Parameters:
    ///   - path: The worktree's folder.
    ///   - limit: The most commits and ignored files to list of those it would lose.
    @concurrent
    public nonisolated func prepareToDelete(worktree path: String, limit: Int) async throws -> WorktreeDeletion.Choice {
        try await WorktreeDeletion.prepare(worktree: path, limit: limit, in: location.commonDirectory, worktrees: try await worktrees(), git: git)
    }

    /// Deletes a linked worktree, then its branch, then the branch on its remote.
    /// A remote is shared, so it goes last: a worktree that git refuses to remove
    /// stops all of this before anyone else can see a change.
    ///
    /// It first stops any fetch that's running, which may be running in the
    /// worktree's folder.
    ///
    /// - Throws: `GitError` when git refuses to remove the worktree, so nothing has
    ///   changed, or `WorktreeDeletion.Stopped` when it stopped after that.
    public func delete(_ deletion: WorktreeDeletion) async throws {
        await clearTheWayForSomeone()
        let directory = location.commonDirectory
        _ = try await Self.run(deletion.removeArguments, in: directory, git: git)
        do {
            try await deletion.branch?.run(in: directory, git: git)
        } catch {
            throw WorktreeDeletion.Stopped(at: .branch, message: (error as? GitError)?.message ?? String(describing: error))
        }
        guard let remoteBranch = deletion.remoteBranch else { return }
        do {
            try await delete(remoteBranch, in: directory)
        } catch {
            throw WorktreeDeletion.Stopped(at: .remoteBranch, message: (error as? GitError)?.message ?? String(describing: error))
        }
    }

    /// Finds out what's worth knowing before reverting a commit in a worktree,
    /// without changing anything.
    ///
    /// - Throws: `CommitRevert.Missing` when the repository doesn't have the commit.
    @concurrent
    public nonisolated func prepareToRevert(_ commit: ObjectID, in worktree: String) async throws -> CommitRevert {
        guard let info = try await commits([commit]).first ?? nil else { throw CommitRevert.Missing(commit: commit) }
        return try await CommitRevert.prepare(info, in: worktree, format: location.format, git: git)
    }

    /// Reverts a commit in a worktree, against its `HEAD`.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    @concurrent
    public nonisolated func revert(_ revert: CommitRevert, _ way: CommitRevert.Way, in worktree: String) async throws -> CommitRevert.Outcome {
        try await revert.run(way, in: worktree, git: git)
    }

    /// Says whether a worktree is partway through a merge, a rebase or a revert.
    @concurrent
    public nonisolated func stoppedWork(in worktree: String) async throws -> StoppedWork? {
        try await RemoteCommands.stoppedWork(in: worktree, git: git)
    }

    /// Says the same from the files git keeps for it, without running git, for
    /// a quick look at every worktree. It's nil when it can't find the
    /// worktree's git directory.
    @concurrent
    public nonisolated func stoppedWorkFromFiles(in worktree: String) async -> StoppedWork? {
        RemoteCommands.stoppedWorkFromFiles(in: worktree)
    }

    /// Goes back to before a merge, a rebase or a revert that stopped partway.
    @concurrent
    public nonisolated func abort(_ work: StoppedWork, in worktree: String) async throws {
        _ = try await Self.run(work.abortArguments, in: worktree, git: git)
    }

    /// Sets aside a worktree's uncommitted changes in a stash when some of them are
    /// in the way of a pull or of going to a commit, which git would otherwise
    /// refuse (decision 58).
    ///
    /// - Returns: Where they went, or nil when nothing is in the way.
    /// - Throws: `GitError` when git can't make the stash, which changes nothing.
    @concurrent
    public nonisolated func setAsideChanges(inTheWayOf move: ChangesAside.Move, message: String, in worktree: String) async throws -> ChangesAside? {
        try await ChangesAside.setAside(for: move, message: message, in: worktree, git: git)
    }

    /// Puts back changes that were set aside, where `HEAD` is now.
    ///
    /// - Throws: `ChangesAside.Missing` when the stash has gone, or `GitError`.
    @concurrent
    public nonisolated func putBack(_ aside: ChangesAside, in worktree: String) async throws -> ChangesAside.PutBack {
        try await aside.putBack(in: worktree, git: git)
    }

    /// Goes back to before a move whose changes came back with conflicts, or
    /// that stopped partway with them still aside, and puts them back there.
    ///
    /// - Throws: `ChangesAside.Missing` when the stash has gone, or `GitError`.
    @concurrent
    public nonisolated func undo(puttingBack aside: ChangesAside, stopped: StoppedWork?, in worktree: String) async throws -> ChangesAside.PutBack {
        try await aside.undo(stopped: stopped, in: worktree, git: git)
    }

    /// Makes a new branch on the commit a worktree is on, and switches to it
    /// there or in a new worktree.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    @concurrent
    public nonisolated func create(_ branch: NewBranch, in worktree: String) async throws {
        _ = try await Self.run(branch.arguments, in: worktree, git: git)
    }

    /// Puts files into a worktree's index as they are on disk now, including
    /// removing the ones that are gone.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    @concurrent
    public nonisolated func stage(_ files: [DiffFile], in worktree: String) async throws {
        try await IndexCommands.stage(files.map(\.path), in: worktree, git: git)
    }

    /// Puts everything in a worktree into its index.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    @concurrent
    public nonisolated func stageEverything(in worktree: String) async throws {
        try await IndexCommands.stageEverything(in: worktree, git: git)
    }

    /// Takes files back out of a worktree's index, leaving them as they are on
    /// disk. A file that moved takes the place it came from with it, or the old
    /// one would stay staged as deleted.
    ///
    /// - Throws: `GitError` when git refuses, which says why.
    @concurrent
    public nonisolated func unstage(_ files: [DiffFile], in worktree: String) async throws {
        try await IndexCommands.unstage(files.flatMap { [$0.path, $0.oldPath].compactMap(\.self) }, in: worktree, git: git)
    }

    /// Takes one hunk out of a file in a worktree, and says how to bring it back.
    ///
    /// - Throws: `GitError` when the hunk's lines have changed since, which changes
    ///   nothing.
    @concurrent
    public nonisolated func discard(_ hunk: HunkPatch, in worktree: String) async throws -> DiscardedChanges {
        try await DiscardCommands.discard(hunk, in: worktree, git: git)
    }

    /// Takes files of a group back to what git has for them, or moves them to the
    /// Trash when it has nothing, and says how to bring them back.
    ///
    /// - Throws: `GitError` when git refuses, or a file error from the Trash.
    @concurrent
    public nonisolated func discard(_ files: [DiffFile], from group: WorktreeChanges.Group, in worktree: String) async throws -> DiscardedChanges {
        try await DiscardCommands.discard(files, from: group, in: worktree, git: git, trash: trash)
    }

    /// Takes a worktree back to `HEAD`, moves these files to the Trash, and says how
    /// to bring it all back.
    ///
    /// - Throws: `GitError` when git refuses, or a file error from the Trash.
    @concurrent
    public nonisolated func discardEverything(trashing files: [DiffFile], in worktree: String) async throws -> DiscardedChanges {
        try await DiscardCommands.discardEverything(trashing: files, in: worktree, git: git, trash: trash)
    }

    /// Brings back what a discard took.
    ///
    /// - Throws: `GitError` when the file has changed where the lines would go, or a
    ///   file error when a trashed file can't go back.
    @concurrent
    public nonisolated func bringBack(_ discarded: DiscardedChanges, in worktree: String) async throws {
        try await DiscardCommands.bringBack(discarded, in: worktree, git: git)
    }

    /// Makes a commit from a worktree's index, with the user's hooks and signing.
    /// Cancelling it stops git.
    ///
    /// - Throws: `GitError` when git or a hook refuses, which says why.
    @concurrent
    public nonisolated func commit(_ request: CommitRequest, in worktree: String) async throws -> MadeCommit {
        try await IndexCommands.commit(request, in: worktree, git: git)
    }

    /// Takes back a commit Roga made, leaving what it had in the index.
    ///
    /// - Throws: `HeadMoved` when something else has moved `HEAD` since, or
    ///   `GitError` when git refuses.
    @concurrent
    public nonisolated func undo(_ commit: MadeCommit, in worktree: String) async throws {
        try await IndexCommands.undo(commit, in: worktree, git: git)
    }

    /// Goes on with a rebase that stopped, keeping its message.
    ///
    /// - Throws: `GitError` when git refuses or stops again, which says why.
    @concurrent
    public nonisolated func continueRebase(in worktree: String) async throws {
        try await IndexCommands.continueRebase(in: worktree, git: git)
    }

    /// The message git has ready for what a worktree is partway through.
    @concurrent
    public nonisolated func message(for work: StoppedWork, in worktree: String) async throws -> String? {
        try await IndexCommands.message(for: work, in: worktree, git: git)
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

    /// Ends the session's git processes, and stops watching the repository.
    /// Dropping the session does the same, except that an update of the
    /// commit-graph files runs to its end.
    public func close() {
        commitGraphUpdate?.cancel()
        runningFetch?.cancel()
        catFile.close()
        watcher.stop()
    }

    // MARK: Watching for changes

    /// What changed on disk, a batch at a time, once `watch(_:)` has started
    /// watching. It's for one listener, the list of repositories, and it ends
    /// when the session closes.
    public nonisolated var changes: AsyncStream<RepositoryChanges> { watcher.changes }

    /// Whether the session is watching the repository. When it isn't, as on a
    /// volume that doesn't record changes, Roga looks again when it becomes
    /// the active app instead.
    public nonisolated var isWatching: Bool { watcher.isWatching }

    /// The number of the latest batch of changes the session has seen.
    public nonisolated var latestChange: Int { watcher.latestChange }

    /// Watches the git directory and the folders of these worktrees, or goes
    /// on watching with these as the worktrees, when they've changed.
    @concurrent
    public nonisolated func watch(_ worktrees: [Worktree]) async {
        watcher.watch(WatchedLayout(commonDirectory: location.commonDirectory, worktrees: worktrees))
    }
}

/// Where a file's changes are, which says how to read its patch.
public enum PatchSource: Sendable, Hashable {
    case commit(ObjectID)
    /// What changed from one commit to another. `from` is nil for nothing at
    /// all, such as the parent of a root commit. `group` says which part of a
    /// stash the file is in, and is nil otherwise.
    case commits(from: ObjectID?, to: ObjectID, group: WorktreeChanges.Group? = nil)

    /// The group of a worktree's changes or a stash's that the file is in.
    public var group: WorktreeChanges.Group? {
        switch self {
        case .commit: nil
        case .commits(_, _, let group): group
        case .worktree(_, let group, _): group
        }
    }
    /// A group of a worktree's uncommitted files. `head` is the commit that
    /// the worktree's staged changes compare with, or nil when there's none yet.
    case worktree(path: String, group: WorktreeChanges.Group, head: ObjectID?)
}

// MARK: - Writing commit messages

extension RepositorySession {
    /// What's staged in a worktree, for an agent to write a commit message
    /// about (decision 41). It compares the index with `HEAD`, or with
    /// `HEAD`'s first parent when amending, so the message covers the whole
    /// amended commit, or with the empty tree when there's no such commit.
    ///
    /// It runs `diff-index --cached -r -M --raw --numstat -z` for the list of
    /// files and `diff-index --cached -r -M -p --no-color --no-ext-diff -U3
    /// --submodule=short` for the patch, at normal priority, because someone
    /// is waiting for the message. The patch is cut down to `budget` bytes, as
    /// `StagedChanges` describes.
    ///
    /// - Parameter worktree: The worktree's folder.
    @concurrent
    public nonisolated func stagedChanges(in worktree: String, amending: Bool, budget: Int = 32_000) async throws -> StagedChanges {
        try await StagedChanges.load(in: worktree, amending: amending, budget: budget, format: location.format, git: git)
    }

    /// The last `count` subjects on a worktree's `HEAD`, following first
    /// parents and leaving out merges, so an agent can match the repository's
    /// style. It's empty before the first commit.
    ///
    /// - Parameter worktree: The worktree's folder.
    @concurrent
    public nonisolated func recentSubjects(in worktree: String, count: Int = 20) async throws -> [String] {
        try await StagedChanges.recentSubjects(in: worktree, count: count, git: git)
    }
}
