import AppKit
import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// The worktree a window shows: its repository's git directory, and the
/// worktree's folder. SwiftUI saves it with the window.
public struct WorktreeSelection: Codable, Hashable, Sendable {
    public var repository: String
    public var worktree: String

    public init(repository: String, worktree: String) {
        self.repository = repository
        self.worktree = worktree
    }
}

/// The repositories in the sidebar, in the order it lists them. Every window
/// lists the same ones and selects a worktree of its own.
///
/// The list opens a session for each repository and keeps it open while the
/// repository is listed, which is what ARCHITECTURE.md calls the registry:
/// windows that show the same repository share its session. The list is
/// saved in Application Support whenever it changes.
@Observable
public final class RepositoryList {
    public private(set) var repositories: [ListedRepository] = []
    /// The worktree selected last in any window.
    var lastSelection: WorktreeSelection? {
        didSet { if lastSelection != oldValue { save() } }
    }
    /// The git that sessions run, once Roga has found it.
    private(set) var git: Git?

    @ObservationIgnored private let store: RepositoryStore
    @ObservationIgnored private var activation: (any NSObjectProtocol)?
    /// How many repositories it's looking at.
    @ObservationIgnored private var looksRunning = 0
    /// The repositories waiting for their turn to be looked at, oldest first.
    @ObservationIgnored private var waitingToLook: [CheckedContinuation<Void, Never>] = []

    /// How many repositories it looks at at once. Each one takes a `git status`
    /// in every worktree, and a list of dozens would otherwise start them all
    /// together every time Roga becomes active.
    static let lookLimit = 4

    public convenience init() {
        self.init(store: .standard)
    }

    init(store: RepositoryStore) {
        self.store = store
        let contents = store.load()
        repositories = contents.repositories.map(ListedRepository.init(saved:))
        lastSelection = contents.lastSelection
    }

    /// A list of repositories that it neither opens nor reads from a file, for
    /// checking what depends on which worktrees are listed. What it saves goes
    /// to a temporary file.
    init(listing repositories: [ListedRepository]) {
        store = RepositoryStore(file: FileManager.default.temporaryDirectory.appending(path: "roga-list-\(UUID().uuidString).json"))
        self.repositories = repositories
    }

    var isConnected: Bool { git != nil }

    /// The repositories grouped by organization, as the sidebar lists them.
    var groups: RepositoryGroups { RepositoryGroups(repositories) }

    /// Opens every repository with `git`, the first time it's called, and
    /// watches each one for changes on disk. After that, whenever Roga becomes
    /// the active app, the list looks again at what it can't watch: repositories
    /// it couldn't open before, such as one on a disk that wasn't mounted, and
    /// any on a volume that doesn't record changes.
    func connect(git: Git) async {
        guard self.git == nil else { return }
        self.git = git
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshUnwatched() }
            }
        }
        await withTaskGroup { group in
            for repository in repositories {
                group.addTask {
                    await self.open(repository, git: git)
                    await self.finishLooking(at: repository)
                }
            }
        }
    }

    func repository(at path: String) -> ListedRepository? {
        repositories.first { $0.path == path }
    }

    /// The listed worktree that a folder is in: the worktree whose folder it
    /// is, or else the deepest one that holds it, because Claude Code puts its
    /// worktrees inside the main checkout. An agent says which folder it works
    /// in, and this is how its session finds its row (decision 41).
    ///
    /// Paths are compared standardized and with symbolic links resolved, since
    /// an agent and git can spell the same folder differently, and a worktree
    /// holds only what's under its folder, so `/a/api` doesn't hold
    /// `/a/api-old`. Bare repositories and worktrees whose folders are gone
    /// hold nothing.
    ///
    /// It asks the file system about every worktree's folder, so it's for
    /// one folder at a time. The agents' monitor, which places a mark for
    /// each row as it draws, resolves folders away from the main actor and
    /// compares them with `deepest(holding:in:)`.
    func worktree(containing folder: String) -> WorktreeSelection? {
        let places = repositories.flatMap { repository in
            repository.worktrees.filter { !$0.isBare && !$0.isPrunable }.map { worktree in
                (folder: Self.comparablePath(worktree.path), value: WorktreeSelection(repository: repository.path, worktree: worktree.path))
            }
        }
        return Self.deepest(holding: Self.comparablePath(folder), in: places)
    }

    /// Of some folders, each with what it stands for, what stands for the
    /// deepest one that holds `target`: `target` itself, or a folder it's
    /// under. Both sides have to be comparable already, as
    /// `comparablePath(_:)` makes them. A match ends at a `/`, so `/a/api`
    /// doesn't hold `/a/api-old`.
    nonisolated static func deepest<Value>(holding target: String, in places: [(folder: String, value: Value)]) -> Value? {
        var found: (value: Value, length: Int)?
        for (folder, value) in places {
            guard folder.count > found?.length ?? -1,
                  target == folder || target.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
            else { continue }
            found = (value, folder.count)
        }
        return found?.value
    }

    /// A path without `.` and `..` or a trailing slash, worked out from its
    /// text alone, without asking the file system.
    nonisolated static func standardizedPath(_ path: String) -> String {
        let standardized = URL(filePath: path).standardized.path(percentEncoded: false)
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// A path without `.` and `..`, a trailing slash or symbolic links, so that
    /// two spellings of a folder compare equal. When the folder doesn't exist,
    /// as when an agent works in one that's been deleted, the part of the path
    /// that does is resolved.
    nonisolated static func comparablePath(_ path: String) -> String {
        let trimmed = standardizedPath(path)
        if let resolved = realpath(trimmed, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (trimmed as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != trimmed else { return trimmed }
        return (comparablePath(parent) as NSString).appendingPathComponent((trimmed as NSString).lastPathComponent)
    }

    /// Adds the repository that `folder` is in, unless it's listed already,
    /// and returns the worktree to select: the one `folder` is in.
    func add(folder: String) async throws -> WorktreeSelection {
        guard let git else { throw RepositoryListError.gitNotFound }
        let found = try await RepositoryLocation.find(containing: folder, git: git)
        let selection = WorktreeSelection(repository: found.commonDirectory, worktree: found.worktree ?? found.commonDirectory)
        if let listed = repository(at: found.commonDirectory) {
            setExpanded(true, listed)
            // The folder may be a worktree that was added since the list
            // last looked.
            await refresh(listed, git: git)
            return selection
        }

        let session = try await RepositorySession.start(location: Self.gitDirectoryLocation(found), git: git)
        let worktrees: [Worktree]
        let owners: [String]
        do {
            worktrees = try await session.worktrees()
            owners = try await session.owners()
        } catch {
            await session.close()
            throw error
        }
        // Another window may have added it while git was running.
        if repository(at: found.commonDirectory) != nil {
            await session.close()
            return selection
        }
        let repository = ListedRepository(saved: RepositoryStore.SavedRepository(
            path: found.commonDirectory,
            bookmark: Self.bookmark(for: found.commonDirectory),
            isExpanded: false
        ))
        repository.owners = owners
        repository.state = .open(session)
        repository.worktrees = worktrees
        repositories.append(repository)
        save()
        listen(to: session, for: repository)
        look(at: repository, session: session)
        return selection
    }

    /// Lists the clones that could be added: the ones in the folders that
    /// listed repositories are in, and in `folders`, leaving out what's listed.
    func clonesToAdd(alsoLookingIn folders: [String] = []) async -> [LocalClone] {
        var seen: Set<String> = []
        let searched = (repositories.map(\.parentFolder) + folders).filter { seen.insert($0).inserted }
        return unlisted(await LocalClones.find(in: searched))
    }

    /// Leaves out the clones the list has, which clones found before one of
    /// them was added still include.
    func unlisted(_ clones: [LocalClone]) -> [LocalClone] {
        let listed = Set(repositories.map(\.path))
        return clones.filter { !listed.contains($0.path + "/.git") }
    }

    /// Takes the repository out of the list and closes its session.
    func remove(_ repository: ListedRepository) {
        repositories.removeAll { $0 === repository }
        if case .open(let session) = repository.state {
            Task { await session.close() }
        }
        if lastSelection?.repository == repository.path {
            lastSelection = nil
        }
        save()
    }

    /// Replaces a repository that can't be found with the one `folder` is
    /// in, and returns the worktree to select.
    func locate(_ repository: ListedRepository, at folder: String) async throws -> WorktreeSelection {
        let selection = try await add(folder: folder)
        if let added = repositories.firstIndex(where: { $0.path == selection.repository }),
           let old = repositories.firstIndex(where: { $0 === repository }),
           added != old
        {
            // Keep the place the old one had in the list.
            let moved = repositories.remove(at: added)
            repositories.insert(moved, at: old > added ? old - 1 : old)
            remove(repository)
        }
        return selection
    }

    /// Mends the links to a repository's linked worktrees after its main worktree
    /// moved, as it has when someone locates it, and lists them again. Each of
    /// them still points into the folder it was in until this runs, so git fails
    /// in all of them.
    ///
    /// - Throws: `GitError` when git can't.
    func repairWorktrees(of repository: ListedRepository) async throws {
        guard let git, let session = repository.session else { return }
        try await session.repairWorktrees()
        await refresh(repository, git: git)
    }

    /// Mends a linked worktree whose folder moved to `folder`, which is how a row
    /// that says its folder is missing finds it again, and returns the worktree to
    /// select there.
    ///
    /// - Throws: `GitError` when git refuses, as when the folder isn't a linked
    ///   worktree, or `RepositoryListError.notTheWorktree` when git mended
    ///   something else, because the folder is another worktree.
    func repair(_ worktree: Worktree, in repository: ListedRepository, movedTo folder: String) async throws -> WorktreeSelection {
        guard let git else { throw RepositoryListError.gitNotFound }
        guard let session = repository.session else { throw RepositoryListError.notOpen }
        try await session.repairWorktrees(movedTo: folder)
        await refresh(repository, git: git)
        let moved = Self.comparablePath(folder)
        guard !repository.worktrees.contains(where: { $0.path == worktree.path }),
              let repaired = repository.worktrees.first(where: { !$0.isPrunable && Self.comparablePath($0.path) == moved })
        else { throw RepositoryListError.notTheWorktree }
        // A collapsed repository goes on showing it where it is now.
        if repository.keptWorktrees.remove(worktree.path) != nil {
            repository.keptWorktrees.insert(repaired.path)
            save()
        }
        return WorktreeSelection(repository: repository.path, worktree: repaired.path)
    }

    /// Records whether a window found conflicts in the worktree it shows, which
    /// may be newer than what the list last found.
    func setHasConflicts(_ hasConflicts: Bool, in selection: WorktreeSelection) {
        guard let repository = repository(at: selection.repository) else { return }
        if repository.conflictedWorktrees.contains(selection.worktree) != hasConflicts {
            if hasConflicts {
                repository.conflictedWorktrees.insert(selection.worktree)
            } else {
                repository.conflictedWorktrees.remove(selection.worktree)
            }
        }
    }

    /// Records how many uncommitted files a window found in the worktree it
    /// shows, which may be newer than what the list last counted.
    func setUncommittedFiles(_ count: Int, in selection: WorktreeSelection) {
        guard let repository = repository(at: selection.repository) else { return }
        if repository.uncommittedFiles[selection.worktree] != count {
            repository.uncommittedFiles[selection.worktree] = count
        }
    }

    func setExpanded(_ isExpanded: Bool, _ repository: ListedRepository) {
        guard repository.isExpanded != isExpanded else { return }
        repository.isExpanded = isExpanded
        if isExpanded { repository.keptWorktrees = [] }
        save()
    }

    /// Keeps a linked worktree showing under its collapsed repository, now that
    /// it's no longer selected, until the repository is expanded.
    func keepShowing(_ selection: WorktreeSelection) {
        guard let repository = repository(at: selection.repository), !repository.isExpanded,
              repository.worktrees.contains(where: { $0.path == selection.worktree && !$0.isMain }),
              repository.keptWorktrees.insert(selection.worktree).inserted
        else { return }
        save()
    }

    /// The worktree a window should show for `selection`: the same one while
    /// it's listed, or its repository's main worktree once it's gone, as
    /// when an agent's worktree is removed.
    func resolve(_ selection: WorktreeSelection?) -> WorktreeSelection? {
        guard let selection, let repository = repository(at: selection.repository) else { return nil }
        guard case .open = repository.state else { return selection }
        if repository.worktrees.contains(where: { $0.path == selection.worktree && !$0.isPrunable }) {
            return selection
        }
        return repository.worktrees.first.map { WorktreeSelection(repository: repository.path, worktree: $0.path) }
    }

    /// Deletes a linked worktree, and whatever else `deletion` says should go with
    /// it. Its row says so until the list has looked again, which is what moves a
    /// window that shows the worktree to the main one.
    ///
    /// - Throws: `GitError` when git refuses to remove the worktree, or
    ///   `WorktreeDeletion.Stopped` when it stopped after that.
    func delete(_ deletion: WorktreeDeletion, in repository: ListedRepository) async throws {
        guard let git, let session = repository.session else { return }
        repository.deletingWorktrees.insert(deletion.worktree)
        var failure: (any Error)?
        do {
            try await session.delete(deletion)
        } catch {
            failure = error
        }
        await refresh(repository, git: git)
        repository.deletingWorktrees.remove(deletion.worktree)
        if !repository.worktrees.contains(where: { $0.path == deletion.worktree }), repository.keptWorktrees.remove(deletion.worktree) != nil {
            save()
        }
        // Whatever went, even partway, windows showing other worktrees have to
        // look again at the repository's refs.
        repository.deletionCount += 1
        if let failure { throw failure }
    }

    /// Lists each open repository's worktrees again, and tries again to open
    /// the repositories that couldn't be opened. It returns once it has looked
    /// at all of them.
    func refresh() async {
        await refresh(repositories)
    }

    /// Does what `refresh()` does for the repositories whose sessions aren't
    /// watching them, which is all that Roga becoming active needs, because
    /// the others say what changed as it happens.
    func refreshUnwatched() async {
        await refresh(repositories.filter { !($0.session?.isWatching ?? false) })
    }

    private func refresh(_ repositories: [ListedRepository]) async {
        guard let git else { return }
        await withTaskGroup { group in
            for repository in repositories {
                group.addTask {
                    await self.refresh(repository, git: git)
                    await self.finishLooking(at: repository)
                }
            }
        }
    }

    /// Lists a repository's worktrees again, because one of them changed. It
    /// returns once the sidebar has the list, which anything someone asked for
    /// can rely on, rather than waiting for what else it reads about them.
    func refresh(repositoryAt path: String) async {
        guard let git, let repository = repository(at: path) else { return }
        await refresh(repository, git: git)
    }

    /// Lists a repository's worktrees again, then looks at them for `request`,
    /// and counts the files of any worktree that's new or whose branch or commit
    /// moved, since what's staged compares with that commit, and a commit
    /// doesn't always write the index.
    private func refresh(_ repository: ListedRepository, git: Git, for request: LookRequest = .everything) async {
        switch repository.state {
        case .opening:
            break
        case .open(let session):
            do {
                let worktrees = try await session.worktrees()
                var request = request
                if worktrees != repository.worktrees {
                    let before = Dictionary(repository.worktrees.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                    let moved = worktrees.filter { worktree in
                        guard let old = before[worktree.path] else { return true }
                        return old.head != worktree.head || old.branch != worktree.branch
                    }
                    request.counts?.formUnion(moved.map(\.path))
                    repository.worktrees = worktrees
                    await session.watch(worktrees)
                } else if !session.isWatching {
                    await session.watch(worktrees)
                }
                look(at: repository, session: session, for: request)
            } catch {
                guard !FileManager.default.fileExists(atPath: repository.path) else { return }
                await session.close()
                // Its bookmark may know where it went.
                await open(repository, git: git)
            }
        case .missing, .failed:
            await open(repository, git: git)
        }
    }

    /// Reads who owns the repository, in case its remotes changed. It keeps
    /// what it knew when git can't say.
    private func updateOwners(of repository: ListedRepository, session: RepositorySession) async {
        let owners: [String]
        do {
            owners = try await session.owners()
        } catch {
            return
        }
        if owners != repository.owners {
            repository.owners = owners
            save()
        }
    }

    // MARK: Changes on disk

    /// Hears what changes on disk in a repository from its session, which
    /// starts watching it here. The list is the session's one listener, and
    /// it hands on to windows what concerns them, through `refsChange` and
    /// `fileChanges`. Listening ends when the session closes.
    private func listen(to session: RepositorySession, for repository: ListedRepository) {
        repository.listening?.cancel()
        repository.listening = Task { [weak self] in
            await session.watch(repository.worktrees)
            for await changes in session.changes {
                guard let self, let git else { return }
                await hear(changes, in: repository, session: session, git: git)
            }
        }
    }

    /// Updates what a repository's rows show after a change on disk, reading
    /// only what it affects: the counts of the worktrees whose files changed,
    /// and when refs moved, how far each branch is from its upstream. Each row
    /// also has its worktree's branch and commit, which `git worktree list`
    /// reads, so refs moving lists the worktrees again too.
    private func hear(_ changes: RepositoryChanges, in repository: ListedRepository, session: RepositorySession, git: Git) async {
        let refsMoved = changes.refs || !changes.heads.isEmpty
        if refsMoved { repository.refsChange = changes.number }
        for worktree in changes.files { repository.fileChanges[worktree] = changes.number }
        let request = LookRequest(owners: changes.config, counts: changes.files, upstreams: refsMoved || changes.worktreeList, asNewAs: changes.number)
        if refsMoved || changes.worktreeList {
            await refresh(repository, git: git, for: request)
        } else {
            look(at: repository, session: session, for: request)
        }
    }

    /// What a look at a repository reads. Asking for a look while one runs adds
    /// to what the next one reads.
    struct LookRequest: Equatable {
        /// Whether to read who owns the repository, from its remotes.
        var owners = false
        /// The worktrees whose uncommitted files to count, by their folders, or
        /// nil for every worktree.
        var counts: Set<String>? = []
        /// Whether to read how far each branch is from its upstream.
        var upstreams = false
        /// For a look because of a change on disk, the change's number, which
        /// lets it share a `git status` with a window that looks at the same
        /// worktree. Nil when it has to run git afresh.
        var asNewAs: Int?

        /// A look at everything, afresh, as when the repository opens.
        static let everything = LookRequest(owners: true, counts: nil, upstreams: true)

        /// Whether it's only because of changes on disk. Those wait a moment after
        /// the look before them, so that a build or a long rebase can't keep git
        /// running.
        var isPaced: Bool { asNewAs != nil }

        func adding(_ other: LookRequest) -> LookRequest {
            var counts: Set<String>?
            if let mine = self.counts, let theirs = other.counts { counts = mine.union(theirs) }
            var asNewAs: Int?
            if let mine = self.asNewAs, let theirs = other.asNewAs { asNewAs = max(mine, theirs) }
            return LookRequest(owners: owners || other.owners, counts: counts, upstreams: upstreams || other.upstreams, asNewAs: asNewAs)
        }
    }

    /// Reads what the rows of a repository's worktrees need beyond the list of
    /// them, without anyone waiting, because that takes a while in a large
    /// worktree. Only one look runs in a repository. Asking during one looks once
    /// more when it's done, however many times it's asked, because something may
    /// have changed since it started.
    private func look(at repository: ListedRepository, session: RepositorySession, for request: LookRequest = .everything) {
        repository.pendingLook = repository.pendingLook?.adding(request) ?? request
        guard repository.look == nil else { return }
        repository.look = Task {
            while let pending = repository.pendingLook {
                // The look before may have been in another task, since each
                // ends when nothing more was asked for while it ran.
                if pending.isPaced, let last = repository.lastLook {
                    await ChangePacing.wait(afterLookFrom: last.started, to: last.finished)
                }
                // More may have been asked for while it waited.
                guard let request = repository.pendingLook else { break }
                repository.pendingLook = nil
                await takeTurnToLook()
                let started = ContinuousClock.now
                if request.owners { await updateOwners(of: repository, session: session) }
                await countUncommittedFiles(in: repository, session: session, only: request.counts, asNewAs: request.asNewAs)
                if request.upstreams { await readUpstreams(of: repository, session: session) }
                finishTurnToLook()
                repository.lastLook = (started, .now)
            }
            repository.look = nil
        }
    }

    /// Returns once a look that's running in a repository is done.
    private func finishLooking(at repository: ListedRepository) async {
        await repository.look?.value
    }

    private func takeTurnToLook() async {
        if looksRunning < Self.lookLimit {
            looksRunning += 1
        } else {
            await withCheckedContinuation { waitingToLook.append($0) }
        }
    }

    private func finishTurnToLook() {
        if waitingToLook.isEmpty {
            looksRunning -= 1
        } else {
            waitingToLook.removeFirst().resume()
        }
    }

    /// Counts the uncommitted files of each of a repository's worktrees, or of
    /// `only` these, one worktree at a time and at utility priority, because
    /// each one looks at every file in the worktree. One that git can't look at
    /// has no count. The same listing says which of them have conflicts, and the
    /// files git keeps for a merge or a rebase say whether one stopped partway.
    ///
    /// - Parameter change: The change on disk that the counts have to be as new
    ///   as, which lets a window looking at the same worktree share git's work,
    ///   or nil to run git afresh.
    private func countUncommittedFiles(in repository: ListedRepository, session: RepositorySession, only: Set<String>? = nil, asNewAs change: Int? = nil) async {
        // Counting only some of them keeps what it knew about the others.
        var counts = only == nil ? [:] : repository.uncommittedFiles
        var conflicted = only == nil ? [] : repository.conflictedWorktrees
        var unfinished = only == nil ? [:] : repository.unfinishedWork
        for worktree in repository.worktrees where !worktree.isBare && !worktree.isPrunable && only?.contains(worktree.path) != false {
            counts[worktree.path] = nil
            conflicted.remove(worktree.path)
            unfinished[worktree.path] = nil
            let status = if let change {
                try? await session.status(in: worktree.path, isUpkeep: true, asNewAs: change)
            } else {
                try? await session.status(in: worktree.path, isUpkeep: true)
            }
            guard let status else { continue }
            counts[worktree.path] = status.fileCount
            if !status.conflicted.isEmpty { conflicted.insert(worktree.path) }
            let stopped = await session.stoppedWorkFromFiles(in: worktree.path)
            unfinished[worktree.path] = UnfinishedWork(work: stopped, conflicts: status.conflicted.count)
        }
        if counts != repository.uncommittedFiles { repository.uncommittedFiles = counts }
        if conflicted != repository.conflictedWorktrees { repository.conflictedWorktrees = conflicted }
        if unfinished != repository.unfinishedWork { repository.unfinishedWork = unfinished }
    }

    /// Reads how far each worktree's branch is from its upstream, with one git
    /// for all of them.
    private func readUpstreams(of repository: ListedRepository, session: RepositorySession) async {
        let branches = repository.worktrees.compactMap { $0.isPrunable ? nil : $0.branch }
        guard let worktree = repository.worktrees.first(where: { !$0.isPrunable }),
              let upstreams = try? await session.upstreams(of: branches, in: worktree.path)
        else { return }
        if upstreams != repository.upstreams { repository.upstreams = upstreams }
    }

    /// Opens a session for the repository at its path, or where its bookmark
    /// says it moved to.
    private func open(_ repository: ListedRepository, git: Git) async {
        var path = repository.path
        if !FileManager.default.fileExists(atPath: path),
           let bookmark = repository.bookmark,
           let moved = Self.resolve(bookmark)
        {
            path = moved
        }
        guard FileManager.default.fileExists(atPath: path) else {
            repository.state = .missing
            return
        }
        repository.state = .opening
        do {
            let location = try await RepositoryLocation.find(containing: path, git: git)
            let session = try await RepositorySession.start(location: Self.gitDirectoryLocation(location), git: git)
            if location.commonDirectory != repository.path {
                // It moved, which leaves each linked worktree pointing into the
                // folder it was in. There's nothing to choose, and when this
                // fails they're no worse off.
                try? await session.repairWorktrees()
            }
            let worktrees = try await session.worktrees()
            guard repositories.contains(where: { $0 === repository }) else {
                await session.close()
                return
            }
            repository.worktrees = worktrees
            repository.state = .open(session)
            listen(to: session, for: repository)
            if location.commonDirectory != repository.path || repository.bookmark == nil {
                let old = repository.path
                repository.path = location.commonDirectory
                repository.bookmark = Self.bookmark(for: location.commonDirectory)
                if lastSelection?.repository == old {
                    // Its worktrees moved with it.
                    lastSelection = worktrees.first.map { WorktreeSelection(repository: repository.path, worktree: $0.path) }
                }
                save()
            }
            look(at: repository, session: session)
        } catch {
            repository.state = .failed(String(describing: error))
        }
    }

    private func save() {
        store.save(RepositoryStore.Contents(repositories: repositories.map(\.saved), lastSelection: lastSelection))
    }

    /// The repository without the worktree it was found from, so that the
    /// session runs git in the git directory, which lasts as long as the
    /// repository does.
    private static func gitDirectoryLocation(_ location: RepositoryLocation) -> RepositoryLocation {
        var location = location
        location.worktree = nil
        return location
    }

    /// Roga isn't sandboxed (decision 1), so the bookmark leaves out the
    /// security scope that a sandboxed app would need to open the folder.
    private static func bookmark(for path: String) -> Data? {
        try? URL(filePath: path, directoryHint: .isDirectory).bookmarkData(options: .withoutImplicitSecurityScope)
    }

    /// Where a bookmark's folder is now, without asking the user anything or
    /// mounting a disk.
    private static func resolve(_ bookmark: Data) -> String? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withoutUI, .withoutMounting],
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return (url.path(percentEncoded: false) as NSString).standardizingPath
    }
}

/// A repository in the sidebar.
@Observable
public final class ListedRepository: Identifiable {
    enum State {
        case opening
        case open(RepositorySession)
        /// Its git directory is gone, and its bookmark didn't find where it
        /// moved.
        case missing
        /// git couldn't open it. The message says why.
        case failed(String)
    }

    /// The repository's git directory, which identifies it.
    fileprivate(set) var path: String
    fileprivate(set) var bookmark: Data?
    fileprivate(set) var isExpanded: Bool
    /// The linked worktrees it goes on showing while it's collapsed, by their
    /// folders: the ones that were selected while it was.
    fileprivate(set) var keptWorktrees: Set<String>
    /// Who owns the repository, from its remotes' URLs, with `origin`'s owner
    /// first.
    fileprivate(set) var owners: [String]
    fileprivate(set) var state = State.opening
    /// The main worktree first, then the linked ones.
    fileprivate(set) var worktrees: [Worktree] = []
    /// How many files have uncommitted changes in each worktree, by its folder.
    fileprivate(set) var uncommittedFiles: [String: Int] = [:]
    /// The folders of the worktrees that have conflicts.
    fileprivate(set) var conflictedWorktrees: Set<String> = []
    /// What each worktree is stuck partway through, by its folder, for the
    /// worktrees that are.
    fileprivate(set) var unfinishedWork: [String: UnfinishedWork] = [:]
    /// How far each worktree's branch is from its upstream, by the branch's full
    /// name, for the branches that have one.
    fileprivate(set) var upstreams: [String: UpstreamCounts] = [:]
    /// The linked worktrees being deleted, by their folders.
    fileprivate(set) var deletingWorktrees: Set<String> = []
    /// How many deletions have finished, for windows to look at the repository's
    /// refs again.
    fileprivate(set) var deletionCount = 0
    /// The number of the latest change on disk that moved a ref or a worktree's
    /// `HEAD`, for windows to look at the repository's refs and history again.
    fileprivate(set) var refsChange = 0
    /// The number of the latest change on disk to each worktree's uncommitted
    /// files, by its folder, for a window that shows it to look again.
    fileprivate(set) var fileChanges: [String: Int] = [:]
    /// The look at its worktrees that's running.
    @ObservationIgnored fileprivate var look: Task<Void, Never>?
    /// What the next look reads, once the running one is done.
    @ObservationIgnored fileprivate var pendingLook: RepositoryList.LookRequest?
    /// When the last look started and finished, which a look because of changes
    /// on disk waits for, as `ChangePacing` says.
    @ObservationIgnored fileprivate var lastLook: (started: ContinuousClock.Instant, finished: ContinuousClock.Instant)?
    /// Hearing what changes on disk from the repository's session.
    @ObservationIgnored fileprivate var listening: Task<Void, Never>?

    fileprivate init(saved: RepositoryStore.SavedRepository) {
        path = saved.path
        bookmark = saved.bookmark
        isExpanded = saved.isExpanded
        keptWorktrees = Set(saved.keptWorktrees ?? [])
        owners = (saved.owner.map { [$0] } ?? []) + (saved.moreOwners ?? [])
    }

    /// A repository that isn't in a list, for checking how a sidebar lays out.
    init(path: String, owners: [String] = [], isExpanded: Bool = false, keptWorktrees: Set<String> = [], state: State = .opening, worktrees: [Worktree] = [], uncommittedFiles: [String: Int] = [:], conflictedWorktrees: Set<String> = [], unfinishedWork: [String: UnfinishedWork] = [:], upstreams: [String: UpstreamCounts] = [:], deletingWorktrees: Set<String> = []) {
        self.path = path
        self.owners = owners
        self.isExpanded = isExpanded
        self.keptWorktrees = keptWorktrees
        self.state = state
        self.worktrees = worktrees
        self.uncommittedFiles = uncommittedFiles
        self.conflictedWorktrees = conflictedWorktrees
        self.unfinishedWork = unfinishedWork
        self.upstreams = upstreams
        self.deletingWorktrees = deletingWorktrees
    }

    var name: String { RepositoryLocation.name(gitDirectory: path) }

    /// The repository's name with its owner in front, as in `git/git`, for
    /// when the sidebar lists it among other owners' repositories.
    var nameWithOwner: String { owners.first.map { $0 + "/" + name } ?? name }

    /// The folder that holds the repository's files, or a bare repository's
    /// git directory. It comes from the git directory, like the name, so it's
    /// known for a repository that's missing.
    var folder: String {
        (path as NSString).lastPathComponent == ".git" ? (path as NSString).deletingLastPathComponent : path
    }

    /// The folder its `folder` is in.
    var parentFolder: String { (folder as NSString).deletingLastPathComponent }

    /// The main worktree, which is what the repository's row selects. A
    /// repository that isn't open yet goes by its folder, and once it's open,
    /// `RepositoryList.resolve(_:)` corrects that if it needs to.
    var home: WorktreeSelection {
        WorktreeSelection(repository: path, worktree: worktrees.first?.path ?? folder)
    }

    var session: RepositorySession? {
        if case .open(let session) = state { session } else { nil }
    }

    fileprivate var saved: RepositoryStore.SavedRepository {
        RepositoryStore.SavedRepository(path: path, bookmark: bookmark, isExpanded: isExpanded, keptWorktrees: keptWorktrees.isEmpty ? nil : keptWorktrees.sorted(), owner: owners.first, moreOwners: owners.count > 1 ? Array(owners.dropFirst()) : nil)
    }
}

enum RepositoryListError: Error, CustomStringConvertible {
    case gitNotFound
    /// The repository isn't open, so git can't be run in it yet.
    case notOpen
    /// git mended nothing for the worktree, because the folder it was given is
    /// another worktree.
    case notTheWorktree

    var description: String {
        switch self {
        case .gitNotFound: "Roga hasn't found git yet."
        case .notOpen: "Roga hasn't opened the repository yet."
        case .notTheWorktree: "That folder is another worktree."
        }
    }
}
