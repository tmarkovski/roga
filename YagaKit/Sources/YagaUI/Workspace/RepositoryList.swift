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
    /// The git that sessions run, once yaga has found it.
    private(set) var git: Git?

    @ObservationIgnored private let store: RepositoryStore
    @ObservationIgnored private var activation: (any NSObjectProtocol)?

    public convenience init() {
        self.init(store: .standard)
    }

    init(store: RepositoryStore) {
        self.store = store
        let contents = store.load()
        repositories = contents.repositories.map(ListedRepository.init(saved:))
        lastSelection = contents.lastSelection
    }

    var isConnected: Bool { git != nil }

    /// The repositories grouped the way the rail picks them.
    var groups: RepositoryGroups { RepositoryGroups(repositories) }

    /// Opens every repository with `git`, the first time it's called. After
    /// that, whenever yaga becomes the active app, the list looks for
    /// worktrees that were added or removed, and for repositories it
    /// couldn't open before, such as one on a disk that wasn't mounted.
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
                Task { await self.refresh() }
            }
        }
        await withTaskGroup { group in
            for repository in repositories {
                group.addTask { await self.open(repository, git: git) }
            }
        }
    }

    func repository(at path: String) -> ListedRepository? {
        repositories.first { $0.path == path }
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

        let session = try RepositorySession(location: Self.gitDirectoryLocation(found), git: git)
        let worktrees: [Worktree]
        let origin: String?
        do {
            worktrees = try await session.worktrees()
            origin = try await session.originURL()
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
            isExpanded: false,
            owner: origin.flatMap(RemoteAddress.owner)
        ))
        repository.state = .open(session)
        repository.worktrees = worktrees
        repositories.append(repository)
        save()
        Task { await countUncommittedFiles(in: repository, session: session) }
        return selection
    }

    /// Lists the clones that could be added: the ones in the folders that
    /// listed repositories are in, and in `folders`, leaving out what's listed.
    func clonesToAdd(alsoLookingIn folders: [String] = []) async -> [LocalClone] {
        guard let git else { return [] }
        var seen: Set<String> = []
        let searched = (repositories.map(\.parentFolder) + folders).filter { seen.insert($0).inserted }
        let listed = Set(repositories.map(\.path))
        return await LocalClones.find(in: searched, git: git).filter { !listed.contains($0.path + "/.git") }
    }

    /// The worktree a window should show after picking `scope`: the one it
    /// showed there last, then `current` if it's there, then the first
    /// repository's main worktree. Picking All leaves the window as it is, so
    /// it's nil.
    func selectionToShow(in scope: SidebarScope, place: SidebarPlace, current: WorktreeSelection?) -> WorktreeSelection? {
        guard scope != .all else { return nil }
        let repositories = groups.repositories(in: scope)
        func isListed(_ selection: WorktreeSelection?) -> Bool {
            repositories.contains { $0.path == selection?.repository }
        }
        if let last = resolve(place.lastSelections[scope]), isListed(last) { return last }
        if isListed(current) { return current }
        return repositories.first?.home
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

    /// Lists each open repository's worktrees again, and tries again to open
    /// the repositories that couldn't be opened.
    func refresh() async {
        guard let git else { return }
        await withTaskGroup { group in
            for repository in repositories {
                group.addTask { await self.refresh(repository, git: git) }
            }
        }
    }

    /// Lists a repository's worktrees again, because one of them changed.
    func refresh(repositoryAt path: String) async {
        guard let git, let repository = repository(at: path) else { return }
        await refresh(repository, git: git)
    }

    private func refresh(_ repository: ListedRepository, git: Git) async {
        switch repository.state {
        case .opening:
            break
        case .open(let session):
            do {
                let worktrees = try await session.worktrees()
                if worktrees != repository.worktrees { repository.worktrees = worktrees }
                await updateOwner(of: repository, session: session)
                await countUncommittedFiles(in: repository, session: session)
            } catch {
                guard !FileManager.default.fileExists(atPath: repository.path) else { return }
                await session.close()
                repository.state = .missing
            }
        case .missing, .failed:
            await open(repository, git: git)
        }
    }

    /// Reads who owns the repository, in case its `origin` changed. It keeps
    /// what it knew when git can't say.
    private func updateOwner(of repository: ListedRepository, session: RepositorySession) async {
        let owner: String?
        do {
            owner = try await session.originURL().flatMap(RemoteAddress.owner)
        } catch {
            return
        }
        if owner != repository.owner {
            repository.owner = owner
            save()
        }
    }

    /// Counts the uncommitted files of each of a repository's worktrees, one
    /// worktree at a time and at low priority, because each one looks at every
    /// file in the worktree. One that git can't look at has no count.
    private func countUncommittedFiles(in repository: ListedRepository, session: RepositorySession) async {
        var counts: [String: Int] = [:]
        for worktree in repository.worktrees where !worktree.isBare && !worktree.isPrunable {
            if let status = try? await session.status(in: worktree.path, isUpkeep: true) { counts[worktree.path] = status.fileCount }
        }
        if counts != repository.uncommittedFiles { repository.uncommittedFiles = counts }
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
            let session = try RepositorySession(location: Self.gitDirectoryLocation(location), git: git)
            let worktrees = try await session.worktrees()
            guard repositories.contains(where: { $0 === repository }) else {
                await session.close()
                return
            }
            repository.worktrees = worktrees
            repository.state = .open(session)
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
            await updateOwner(of: repository, session: session)
            await countUncommittedFiles(in: repository, session: session)
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

    /// yaga isn't sandboxed (decision 1), so the bookmark leaves out the
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
    /// Who owns the repository, from its `origin` URL, or nil without one.
    fileprivate(set) var owner: String?
    fileprivate(set) var state = State.opening
    /// The main worktree first, then the linked ones.
    fileprivate(set) var worktrees: [Worktree] = []
    /// How many files have uncommitted changes in each worktree, by its folder.
    fileprivate(set) var uncommittedFiles: [String: Int] = [:]

    fileprivate init(saved: RepositoryStore.SavedRepository) {
        path = saved.path
        bookmark = saved.bookmark
        isExpanded = saved.isExpanded
        keptWorktrees = Set(saved.keptWorktrees ?? [])
        owner = saved.owner
    }

    /// A repository that isn't in a list, for checking how a sidebar lays out.
    init(path: String, owner: String? = nil, isExpanded: Bool = false, keptWorktrees: Set<String> = [], state: State = .opening, worktrees: [Worktree] = [], uncommittedFiles: [String: Int] = [:]) {
        self.path = path
        self.owner = owner
        self.isExpanded = isExpanded
        self.keptWorktrees = keptWorktrees
        self.state = state
        self.worktrees = worktrees
        self.uncommittedFiles = uncommittedFiles
    }

    var name: String { RepositoryLocation.name(gitDirectory: path) }

    /// The repository's name with its owner in front, as in `git/git`, for
    /// when the sidebar lists it among other owners' repositories.
    var nameWithOwner: String { owner.map { $0 + "/" + name } ?? name }

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
        RepositoryStore.SavedRepository(path: path, bookmark: bookmark, isExpanded: isExpanded, keptWorktrees: keptWorktrees.isEmpty ? nil : keptWorktrees.sorted(), owner: owner)
    }
}

enum RepositoryListError: Error, CustomStringConvertible {
    case gitNotFound

    var description: String {
        switch self {
        case .gitNotFound: "yaga hasn't found git yet."
        }
    }
}
