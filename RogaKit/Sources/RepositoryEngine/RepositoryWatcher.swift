import Foundation
import GitCore
import GitRunner
import Synchronization

/// Watches a repository's git directory and its worktrees' folders with one
/// FSEvents stream, and says what each batch of changes affects
/// (ARCHITECTURE.md, "Changes on disk"). A session owns one.
///
/// FSEvents hands over a batch about a tenth of a second after the first change
/// in it. The watcher numbers it straight away, sorts its paths, asks git which
/// of the worktrees' files it ignores, and then publishes what's left, unless
/// that's nothing.
final class RepositoryWatcher: Sendable {
    /// What changed, a batch at a time, for one listener.
    let changes: AsyncStream<RepositoryChanges>
    private let continuation: AsyncStream<RepositoryChanges>.Continuation
    private let batches: AsyncStream<Batch>.Continuation
    private let sorting: Task<Void, Never>
    private let state = Mutex(State())

    private struct State {
        var layout: WatchedLayout?
        var stream: FolderWatcher?
        /// The number of the latest batch, which only goes up.
        var latest = 0
        var isStopped = false
    }

    private struct Batch: Sendable {
        var paths: SortedPaths
        var layout: WatchedLayout
    }

    init(git: Git) {
        (changes, continuation) = AsyncStream.makeStream(of: RepositoryChanges.self)
        let (batches, input) = AsyncStream.makeStream(of: Batch.self)
        self.batches = input
        sorting = Task.detached(priority: .utility) { [continuation] in
            var ignored = IgnoredPaths()
            for await batch in batches {
                var changes = batch.paths.changes
                if let worktrees = batch.paths.ignoreRules {
                    for worktree in worktrees { ignored.forget(worktree) }
                } else {
                    ignored.forgetAll()
                }
                for (worktree, paths) in batch.paths.candidates {
                    guard let folder = batch.layout.worktrees.first(where: { $0.path == worktree })?.folder else { continue }
                    if await ignored.anyMatters(paths, in: worktree, folder: folder, git: git) {
                        changes.files.insert(worktree)
                    }
                }
                if !changes.isEmpty { continuation.yield(changes) }
            }
            continuation.finish()
        }
    }

    /// The number of the latest batch FSEvents has handed over, or 0 before the
    /// first.
    var latestChange: Int { state.withLock { $0.latest } }

    /// Whether FSEvents is watching the repository. It isn't before `watch(_:)`,
    /// after `stop()`, or when it couldn't, as on a volume that doesn't record
    /// changes.
    var isWatching: Bool { state.withLock { $0.stream != nil } }

    /// Watches the repository laid out this way, or goes on watching it with
    /// what's changed, such as a new worktree. A new stream starts before the
    /// old one stops, so that nothing that happens in between is missed.
    func watch(_ layout: WatchedLayout) {
        let previous: FolderWatcher? = state.withLock { state in
            guard !state.isStopped, layout != state.layout else { return nil }
            state.layout = layout
            guard state.stream?.folders != layout.folders else { return nil }
            let previous = state.stream
            state.stream = FolderWatcher(folders: layout.folders, excluding: layout.excluded) { [weak self] events in
                self?.receive(events)
            }
            return previous
        }
        previous?.stop()
    }

    /// Stops watching for good, and ends `changes`.
    func stop() {
        let stream: FolderWatcher? = state.withLock { state in
            state.isStopped = true
            state.layout = nil
            defer { state.stream = nil }
            return state.stream
        }
        stream?.stop()
        batches.finish()
    }

    private func receive(_ events: [FolderEvent]) {
        let numbered: (Int, WatchedLayout)? = state.withLock { state in
            guard let layout = state.layout else { return nil }
            state.latest += 1
            return (state.latest, layout)
        }
        guard let numbered else { return }
        let (number, layout) = numbered
        var paths = SortedPaths(events, in: layout)
        guard !paths.isEmpty else { return }
        paths.changes.number = number
        batches.yield(Batch(paths: paths, layout: layout))
    }

    deinit {
        stop()
        sorting.cancel()
    }
}
