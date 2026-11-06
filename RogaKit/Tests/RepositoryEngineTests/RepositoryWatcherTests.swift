import CoreServices
import Foundation
import GitCore
import GitRunner
import Synchronization
import TestSupport
import Testing
@testable import RepositoryEngine

/// Sorting the paths FSEvents reports by what they affect, without FSEvents.
struct SortedPathsTests {
    /// A repository at `/r` with a linked worktree inside its folder, as Claude
    /// Code makes them, and one elsewhere.
    let layout = WatchedLayout(commonDirectory: "/r/.git", watched: [
        WatchedWorktree(path: "/r", folder: "/r", gitFolder: "/r/.git"),
        WatchedWorktree(path: "/r/.claude/worktrees/a", folder: "/r/.claude/worktrees/a", gitFolder: "/r/.git/worktrees/a"),
        WatchedWorktree(path: "/w/b", folder: "/w/b", gitFolder: "/r/.git/worktrees/b"),
    ])

    func sorted(_ paths: String..., flags: Int = kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile) -> SortedPaths {
        SortedPaths(paths.map { FolderEvent(path: $0, flags: FSEventStreamEventFlags(flags)) }, in: layout)
    }

    @Test func watchesTheFoldersThatHoldEverything() {
        #expect(layout.folders == ["/r", "/w/b"])
        #expect(layout.excluded.contains("/r/.git/objects"))
    }

    @Test func refsAndConfigChangeRefs() {
        for path in ["/r/.git/refs/heads/main", "/r/.git/refs/remotes/origin/main", "/r/.git/packed-refs", "/r/.git/refs/stash", "/r/.git/reftable/tables.list"] {
            let paths = sorted(path)
            #expect(paths.changes == RepositoryChanges(number: 0, refs: true), "\(path)")
            #expect(paths.ignoreRules == [])
        }
        let config = sorted("/r/.git/config")
        #expect(config.changes == RepositoryChanges(number: 0, refs: true, config: true))
        #expect(config.ignoreRules == nil)
    }

    @Test func locksObjectsAndLogsChangeNothing() {
        for path in ["/r/.git/refs/heads/main.lock", "/r/.git/index.lock", "/r/.git/objects/ab/cdef", "/r/.git/logs/HEAD", "/r/.git/FETCH_HEAD", "/r/.git/ORIG_HEAD", "/r/.git/COMMIT_EDITMSG", "/r/.git/worktrees/a/logs/HEAD", "/elsewhere/file"] {
            #expect(sorted(path).isEmpty, "\(path)")
        }
    }

    @Test func eachWorktreeHasItsOwnHeadAndIndex() {
        let main = sorted("/r/.git/HEAD")
        #expect(main.changes == RepositoryChanges(number: 0, heads: ["/r"], files: ["/r"]))
        let linked = sorted("/r/.git/worktrees/a/HEAD")
        #expect(linked.changes == RepositoryChanges(number: 0, heads: ["/r/.claude/worktrees/a"], files: ["/r/.claude/worktrees/a"]))
        let index = sorted("/r/.git/worktrees/b/index")
        #expect(index.changes == RepositoryChanges(number: 0, files: ["/w/b"]))
        // A file forced into an ignored folder matters from now on.
        #expect(index.ignoreRules == ["/w/b"])
    }

    @Test func stoppedWorkChangesFiles() {
        for path in ["/r/.git/MERGE_HEAD", "/r/.git/rebase-merge/done", "/r/.git/REVERT_HEAD", "/r/.git/sequencer/todo"] {
            #expect(sorted(path).changes == RepositoryChanges(number: 0, files: ["/r"]), "\(path)")
        }
        #expect(sorted("/r/.git/worktrees/a/rebase-apply/next").changes.files == ["/r/.claude/worktrees/a"])
    }

    @Test func worktreesComingGoingOrLockingChangeTheList() {
        for path in ["/r/.git/worktrees", "/r/.git/worktrees/c", "/r/.git/worktrees/c/HEAD", "/r/.git/worktrees/a/locked", "/r/.git/worktrees/b/gitdir"] {
            #expect(sorted(path).changes == RepositoryChanges(number: 0, worktreeList: true), "\(path)")
        }
    }

    @Test func filesGoToTheDeepestWorktreeThatHoldsThem() {
        let paths = sorted("/r/Sources/a.swift", "/r/.claude/worktrees/a/Sources/b.swift", "/w/b/c.txt")
        #expect(paths.changes.isEmpty)
        #expect(paths.candidates == [
            "/r": [ChangedPath(path: "Sources/a.swift", isFolder: false)],
            "/r/.claude/worktrees/a": [ChangedPath(path: "Sources/b.swift", isFolder: false)],
            "/w/b": [ChangedPath(path: "c.txt", isFolder: false)],
        ])
    }

    @Test func gitFoldersInsideAWorktreeChangeNothing() {
        #expect(sorted("/r/.claude/worktrees/a/.git").isEmpty)
        #expect(sorted("/r/vendor/library/.git/index").isEmpty)
    }

    @Test func aGitignoreChangesWhatItIgnores() {
        let paths = sorted("/r/Sources/.gitignore")
        #expect(paths.candidates["/r"] == [ChangedPath(path: "Sources/.gitignore", isFolder: false)])
        #expect(paths.ignoreRules == ["/r"])
    }

    @Test func foldersSayTheyAreFolders() {
        let paths = sorted("/r/new", flags: kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)
        #expect(paths.candidates["/r"] == [ChangedPath(path: "new", isFolder: true)])
    }

    @Test func onlyAttributesChangeNothing() {
        #expect(sorted("/r/a.txt", flags: kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemIsFile).isEmpty)
        #expect(!sorted("/r/a.txt", flags: kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemModified).isEmpty)
    }

    @Test func aWorktreeWhoseIndexChangedNeedsNoFilesChecked() {
        let paths = sorted("/r/.git/index", "/r/a.txt")
        #expect(paths.changes.files == ["/r"])
        #expect(paths.candidates.isEmpty)
    }

    @Test func losingTrackChangesEverything() {
        let paths = sorted("/r/.git", flags: kFSEventStreamEventFlagMustScanSubDirs)
        #expect(paths.changes.refs && paths.changes.worktreeList && paths.changes.config)
        #expect(paths.changes.files == ["/r", "/r/.claude/worktrees/a", "/w/b"])
        #expect(paths.ignoreRules == nil)
        #expect(sorted("/w/b", flags: kFSEventStreamEventFlagRootChanged).changes.files == ["/w/b"])
    }

    @Test func aBareRepositorysHeadChangesHistory() {
        let bare = WatchedLayout(commonDirectory: "/r.git", watched: [WatchedWorktree(path: "/r.git", folder: nil, gitFolder: "/r.git")])
        let paths = SortedPaths([FolderEvent(path: "/r.git/HEAD", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))], in: bare)
        #expect(paths.changes == RepositoryChanges(number: 0, refs: true, heads: ["/r.git"]))
        #expect(bare.folders == ["/r.git"])
    }
}

/// Asking git which changed paths it ignores.
@Suite(.timeLimit(.minutes(1)))
struct IgnoredPathsTests {
    /// A repository that ignores `build/` and `*.o`, with a file forced into
    /// `kept/`, which it ignores too.
    func makeRepository() async throws -> String {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository + "/kept", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: repository + "/src", withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        try Data("build/\n*.o\nkept/\n".utf8).write(to: URL(filePath: repository + "/.gitignore"))
        try Data("int a;\n".utf8).write(to: URL(filePath: repository + "/src/a.c"))
        try Data("keep\n".utf8).write(to: URL(filePath: repository + "/kept/file"))
        try await runGit("add", ".gitignore", "src", in: repository)
        try await runGit("add", "--force", "kept/file", in: repository)
        return repository
    }

    func file(_ path: String) -> ChangedPath { ChangedPath(path: path, isFolder: false) }

    @Test func findsWhatMatters() async throws {
        let repository = try await makeRepository()
        let git = try await TestGit.make()
        var ignored = IgnoredPaths()
        #expect(!(await ignored.anyMatters([file("build/debug/a.o"), file("build/log.txt")], in: repository, folder: repository, git: git)))
        #expect(!(await ignored.anyMatters([file("src/a.o")], in: repository, folder: repository, git: git)))
        #expect(await ignored.anyMatters([file("src/a.c")], in: repository, folder: repository, git: git))
        #expect(await ignored.anyMatters([file("src/new.c")], in: repository, folder: repository, git: git))
        #expect(await ignored.anyMatters([ChangedPath(path: "docs", isFolder: true)], in: repository, folder: repository, git: git))
        #expect(!(await ignored.anyMatters([ChangedPath(path: "build", isFolder: true)], in: repository, folder: repository, git: git)))
        #expect(await ignored.anyMatters([file("build/a.o"), file("README.md")], in: repository, folder: repository, git: git))
    }

    @Test func aFolderWithATrackedFileIsntIgnored() async throws {
        let repository = try await makeRepository()
        let git = try await TestGit.make()
        var ignored = IgnoredPaths()
        #expect(await ignored.anyMatters([file("kept/file")], in: repository, folder: repository, git: git))
        #expect(!(await ignored.anyMatters([file("kept/other")], in: repository, folder: repository, git: git)))
    }

    @Test func remembersIgnoredFoldersWithoutAskingAgain() async throws {
        let repository = try await makeRepository()
        let git = try await TestGit.make()
        var ignored = IgnoredPaths()
        #expect(!(await ignored.anyMatters([file("build/a.o")], in: repository, folder: repository, git: git)))
        // With the folder gone, git can't run there, which would count as
        // mattering, so only what it remembers can say no.
        #expect(!(await ignored.anyMatters([file("build/b/c.txt")], in: repository, folder: "/nonexistent", git: git)))
        #expect(await ignored.anyMatters([file("src/b.c")], in: repository, folder: "/nonexistent", git: git))
        ignored.forget(repository)
        #expect(await ignored.anyMatters([file("build/b/c.txt")], in: repository, folder: "/nonexistent", git: git))
    }

    @Test func foldersHoldingAPath() {
        #expect(IgnoredPaths.folders(holding: "a/b/c.txt") == ["a/", "a/b/"])
        #expect(IgnoredPaths.folders(holding: "c.txt") == [])
    }

    @Test func readsWhatGitPrints() {
        let output = Array(".gitignore\u{0}1\u{0}build/\u{0}build/\u{0}\u{0}\u{0}\u{0}src/a.c\u{0}".utf8)
        #expect(IgnoredPaths.parse(output) == ["build/"])
    }
}

/// Watching a real repository with FSEvents. Each test waits for FSEvents, so
/// it takes a second or so.
@Suite(.timeLimit(.minutes(1)))
struct RepositoryWatcherTests {
    /// Collects what a session's watcher publishes.
    final class Listener: Sendable {
        private final class Received: Sendable {
            let changes = Mutex<[RepositoryChanges]>([])
        }

        private let received = Received()
        private let task: Task<Void, Never>

        init(_ session: RepositorySession) {
            let received = received
            task = Task {
                for await changes in session.changes {
                    received.changes.withLock { $0.append(changes) }
                }
            }
        }

        var all: [RepositoryChanges] { received.changes.withLock { $0 } }

        /// Waits until what arrived satisfies `condition`, for up to fifteen
        /// seconds, which a busy machine can need, and returns everything that
        /// arrived.
        func wait(until condition: ([RepositoryChanges]) -> Bool) async -> [RepositoryChanges] {
            for _ in 0..<300 {
                let all = all
                if condition(all) { return all }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return all
        }

        deinit { task.cancel() }
    }

    func makeRepository() async throws -> (RepositorySession, String) {
        let repository = try makeTemporaryFolder() + "/repository"
        try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
        try await runGit("init", "--quiet", "--initial-branch=main", in: repository)
        try await runGit("config", "user.name", "Ana", in: repository)
        try await runGit("config", "user.email", "ana@example.com", in: repository)
        // As in a repository where Claude Code makes worktrees, which keeps
        // what's written in a new worktree before it's watched from counting
        // for the main one.
        try write("build/\n.claude/\n", to: ".gitignore", in: repository)
        try write("one\n", to: "a.txt", in: repository)
        try await runGit("add", "--all", in: repository)
        try await runGit("commit", "--quiet", "--message=First", in: repository)
        let session = try await openSession(repository)
        return (session, repository)
    }

    func write(_ text: String, to path: String, in folder: String) throws {
        let file = URL(filePath: folder + "/" + path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// Starts watching, and waits for FSEvents to settle, since a stream that
    /// has just started can report what happened just before it.
    func watch(_ session: RepositorySession) async throws -> Listener {
        let listener = Listener(session)
        await session.watch(try await session.worktrees())
        #expect(session.isWatching)
        try await Task.sleep(for: .milliseconds(300))
        return listener
    }

    @Test func seesAFileChange() async throws {
        let (session, repository) = try await makeRepository()
        let listener = try await watch(session)
        try write("two\n", to: "a.txt", in: repository)
        let changes = await listener.wait { $0.contains { $0.files.contains(repository) } }
        #expect(changes.contains { $0.files.contains(repository) }, "batches seen: \(session.latestChange), published: \(changes)")
        #expect(changes.allSatisfy { $0.number > 0 })
        await session.close()
    }

    @Test func seesACommit() async throws {
        let (session, repository) = try await makeRepository()
        let listener = try await watch(session)
        try write("two\n", to: "a.txt", in: repository)
        try await runGit("commit", "--quiet", "--all", "--message=Second", in: repository)
        let changes = await listener.wait { $0.contains { $0.refs } }
        #expect(changes.contains { $0.refs })
        #expect(changes.contains { $0.files.contains(repository) })
        await session.close()
    }

    @Test func leavesOutWhatGitIgnores() async throws {
        let (session, repository) = try await makeRepository()
        let listener = try await watch(session)
        for index in 0..<20 {
            try write("\(index)\n", to: "build/out/\(index).o", in: repository)
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(listener.all.isEmpty)
        try write("new\n", to: "b.txt", in: repository)
        let changes = await listener.wait { !$0.isEmpty }
        #expect(changes.map(\.files) == [[repository]])
        await session.close()
    }

    @Test func seesANewWorktreeAndWhatsInIt() async throws {
        let (session, repository) = try await makeRepository()
        let listener = try await watch(session)
        let linked = repository + "/.claude/worktrees/feature"
        try await runGit("worktree", "add", "--quiet", "-b", "feature", linked, in: repository)
        _ = await listener.wait { $0.contains { $0.worktreeList } }
        #expect(listener.all.contains { $0.worktreeList })

        await session.watch(try await session.worktrees())
        try await Task.sleep(for: .milliseconds(300))
        let before = listener.all.count
        try write("two\n", to: "a.txt", in: linked)
        let changes = await listener.wait { $0.dropFirst(before).contains { $0.files.contains(linked) } }
        let after = Array(changes.dropFirst(before))
        #expect(after.contains { $0.files.contains(linked) })
        // It's inside the main worktree's folder, but it's a worktree of its own.
        #expect(!after.contains { $0.files.contains(repository) })
        await session.close()
    }

    @Test func endsWhenTheSessionCloses() async throws {
        let (session, _) = try await makeRepository()
        _ = try await watch(session)
        await session.close()
        #expect(!session.isWatching)
        var iterator = session.changes.makeAsyncIterator()
        _ = await iterator.next()
    }

    @Test func sharesAStatusThatStartedAfterAChange() async throws {
        let (session, repository) = try await makeRepository()
        let first = try await session.status(in: repository, asNewAs: 0)
        #expect(first.fileCount == 0)
        try write("two\n", to: "a.txt", in: repository)
        // Nothing has told the session about the change yet, so the last look
        // is as new as it asks for.
        #expect(try await session.status(in: repository, asNewAs: 0).fileCount == 0)
        #expect(try await session.status(in: repository).fileCount == 1)

        let listener = try await watch(session)
        try write("three\n", to: "b.txt", in: repository)
        let changes = await listener.wait { $0.contains { $0.files.contains(repository) } }
        let number = try #require(changes.last { $0.files.contains(repository) }?.number)
        #expect(try await session.status(in: repository, asNewAs: number).fileCount == 2)
        await session.close()
    }
}
