import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

@Suite(.timeLimit(.minutes(1)))
struct RepositoryListTests {
    let folder: String
    let store: RepositoryStore

    init() throws {
        folder = try makeTemporaryFolder()
        store = RepositoryStore(file: URL(filePath: folder + "/support/repositories.json"))
    }

    /// A list read from the store, with every repository opened.
    func makeList() async throws -> RepositoryList {
        let list = RepositoryList(store: store)
        await list.connect(git: try await TestGit.make())
        return list
    }

    @Test func remembersRepositories() async throws {
        let repository = try await Fixture.repository("basic")
        let list = try await makeList()
        let selection = try await list.add(folder: repository + "/src")
        #expect(selection == WorktreeSelection(repository: repository + "/.git", worktree: repository))
        list.lastSelection = selection

        let reopened = try await makeList()
        let listed = try #require(reopened.repositories.first)
        #expect(reopened.repositories.count == 1)
        #expect(listed.path == repository + "/.git")
        #expect(listed.name == "basic")
        #expect(listed.session != nil)
        #expect(listed.worktrees.map(\.path) == [repository])
        #expect(reopened.lastSelection == selection)
    }

    @Test func listsARepositoryOnce() async throws {
        let repository = try await Fixture.repository("basic")
        let list = try await makeList()
        let first = try await list.add(folder: repository)
        let second = try await list.add(folder: repository + "/src")
        #expect(first == second)
        #expect(list.repositories.count == 1)
    }

    @Test func listsTheRepositoryOfALinkedWorktree() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: repository)
        let list = try await makeList()
        let selection = try await list.add(folder: folder + "/notes")
        #expect(selection == WorktreeSelection(repository: repository + "/.git", worktree: folder + "/notes"))
        let listed = try #require(list.repositories.first)
        #expect(listed.name == "basic")
        #expect(listed.worktrees.map(\.path) == [repository, folder + "/notes"])
        #expect(listed.session?.location.worktree == nil)
    }

    @Test func showsANewWorktreeOfAListedRepository() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        let listed = try #require(list.repositories.first)
        list.setExpanded(false, listed)
        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: repository)

        let selection = try await list.add(folder: folder + "/notes")
        #expect(selection == WorktreeSelection(repository: repository + "/.git", worktree: folder + "/notes"))
        #expect(list.repositories.count == 1)
        #expect(listed.isExpanded)
        #expect(listed.worktrees.map(\.path) == [repository, folder + "/notes"])
    }

    @Test func refusesAFolderOutsideARepository() async throws {
        let list = try await makeList()
        await #expect(throws: RepositoryError.self) {
            try await list.add(folder: folder)
        }
        #expect(list.repositories.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.file.path(percentEncoded: false)))
    }

    @Test func removesARepository() async throws {
        let list = try await makeList()
        let selection = try await list.add(folder: try await Fixture.repository("basic"))
        list.lastSelection = selection
        list.remove(try #require(list.repositories.first))
        #expect(list.repositories.isEmpty)
        #expect(list.lastSelection == nil)
        #expect(try await makeList().repositories.isEmpty)
    }

    @Test func followsARepositoryThatMoved() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let first = try await makeList()
        first.lastSelection = try await first.add(folder: repository)
        try FileManager.default.moveItem(atPath: repository, toPath: folder + "/moved")

        let list = try await makeList()
        let listed = try #require(list.repositories.first)
        #expect(listed.path == folder + "/moved/.git")
        #expect(listed.session != nil)
        #expect(list.lastSelection == WorktreeSelection(repository: folder + "/moved/.git", worktree: folder + "/moved"))
        #expect(try await makeList().repositories.first?.path == folder + "/moved/.git")
    }

    @Test func keepsARepositoryThatsGone() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        _ = try await makeList().add(folder: repository)
        try FileManager.default.removeItem(atPath: repository)

        let list = try await makeList()
        let listed = try #require(list.repositories.first)
        guard case .missing = listed.state else {
            Issue.record("The repository is \(listed.state), not missing")
            return
        }
        #expect(listed.name == "basic")
        #expect(try await makeList().repositories.count == 1)
    }

    @Test func findsAMissingRepositoryWhereTheUserSaysItIs() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let list = try await makeList()
        _ = try await list.add(folder: try await Fixture.repository("history") + "/single")
        _ = try await list.add(folder: repository)
        _ = try await list.add(folder: try await Fixture.repository("history") + "/chain")
        try FileManager.default.removeItem(atPath: repository)
        await list.refresh()

        let copy = try await copyRepository(try await Fixture.repository("basic"), into: folder + "/elsewhere")
        let missing = list.repositories[1]
        let selection = try await list.locate(missing, at: copy)
        #expect(selection == WorktreeSelection(repository: copy + "/.git", worktree: copy))
        #expect(list.repositories.map(\.name) == ["single", "basic", "chain"])
        #expect(list.repositories[1].path == copy + "/.git")
    }

    @Test func seesWorktreesThatWereAddedOrRemoved() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let list = try await makeList()
        let main = try await list.add(folder: repository)
        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: repository)
        await list.refresh()
        #expect(list.repositories.first?.worktrees.map(\.path) == [repository, folder + "/notes"])

        let notes = WorktreeSelection(repository: repository + "/.git", worktree: folder + "/notes")
        #expect(list.resolve(notes) == notes)
        try await runGit("worktree", "remove", folder + "/notes", in: repository)
        await list.refresh()
        #expect(list.repositories.first?.worktrees.map(\.path) == [repository])
        // A window that showed the worktree shows the main one instead.
        #expect(list.resolve(notes) == main)
        #expect(list.resolve(WorktreeSelection(repository: folder + "/other/.git", worktree: folder + "/other")) == nil)
    }

    @Test func countsUncommittedFilesInEachWorktree() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: repository)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        let listed = try #require(list.repositories.first)

        try Data("new\n".utf8).write(to: URL(filePath: repository + "/new.txt"))
        try Data("a\n".utf8).write(to: URL(filePath: folder + "/notes/a.txt"))
        try Data("b\n".utf8).write(to: URL(filePath: folder + "/notes/b.txt"))
        await list.refresh()
        #expect(listed.uncommittedFiles == [repository: 1, folder + "/notes": 2])

        // A window's newer count takes over until the list counts again.
        let selection = WorktreeSelection(repository: listed.path, worktree: repository)
        list.setUncommittedFiles(5, in: selection)
        #expect(listed.uncommittedFiles[repository] == 5)
        await list.refresh()
        #expect(listed.uncommittedFiles[repository] == 1)
    }

    @Test func findsWhichWorktreesHaveConflicts() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        try await runGit("config", "user.name", "T", in: repository)
        try await runGit("config", "user.email", "t@example.com", in: repository)
        for (branch, text) in [("one", "one\n"), ("two", "two\n")] {
            try await runGit("checkout", "--quiet", "-B", branch, "HEAD", in: repository)
            try Data(text.utf8).write(to: URL(filePath: repository + "/conflict.txt"))
            try await runGit("add", "conflict.txt", in: repository)
            try await runGit("commit", "--quiet", "-m", branch, in: repository)
            if branch == "one" { try await runGit("checkout", "--quiet", "HEAD~1", in: repository) }
        }
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        let listed = try #require(list.repositories.first)
        await list.refresh()
        #expect(listed.conflictedWorktrees.isEmpty)

        _ = try? await runGit("merge", "one", in: repository)
        await list.refresh()
        #expect(listed.conflictedWorktrees == [repository])

        // A window's newer answer takes over until the list looks again.
        let selection = WorktreeSelection(repository: listed.path, worktree: repository)
        list.setHasConflicts(false, in: selection)
        #expect(listed.conflictedWorktrees.isEmpty)
        await list.refresh()
        #expect(listed.conflictedWorktrees == [repository])
    }

    @Test func countsNothingForABareRepository() async throws {
        let repository = folder + "/bare.git"
        try await TestGit.make().run(GitCommand("init", "--quiet", "--bare", repository))
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        await list.refresh()
        #expect(list.repositories.first?.uncommittedFiles == [:])
    }

    /// A git whose `git status` takes a second, for catching what waits for it and
    /// what runs alongside it.
    func gitWithSlowStatus(log: CommandLog) async throws -> Git {
        var installation = try await TestGit.installation()
        let script = folder + "/slow-git"
        try """
        #!/bin/sh
        case " $* " in *" status "*) sleep 1 ;; esac
        exec "\(installation.executable)" "$@"
        """.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        installation.executable = script
        return Git(installation: installation, log: log, environment: TestGit.isolatedEnvironment)
    }

    func statusCommands(in log: CommandLog) -> [CommandLog.Entry] {
        log.entries.filter { $0.arguments.contains("status") }
    }

    @Test func aChangeSomeoneMadeDoesntWaitForTheCounts() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let list = RepositoryList(store: store)
        await list.connect(git: try await gitWithSlowStatus(log: CommandLog()))
        _ = try await list.add(folder: repository)
        let listed = try #require(list.repositories.first)
        await list.refresh()

        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: repository)
        await list.refresh(repositoryAt: listed.path)

        #expect(listed.worktrees.contains { $0.path == folder + "/notes" })
        #expect(listed.uncommittedFiles[folder + "/notes"] == nil)

        await list.refresh()
        #expect(listed.uncommittedFiles[folder + "/notes"] == 0)
    }

    @Test func looksOnceMoreHoweverOftenItsAskedDuringALook() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let log = CommandLog()
        let list = RepositoryList(store: store)
        await list.connect(git: try await gitWithSlowStatus(log: log))
        _ = try await list.add(folder: repository)
        await list.refresh()
        let before = statusCommands(in: log).count

        // A request that comes before the look has begun to read is answered
        // by that look, so the other two wait until it's reading. Its status
        // takes a second.
        async let first: Void = list.refresh()
        #expect(await AgentTestSupport.eventually { statusCommands(in: log).count > before })
        async let second: Void = list.refresh()
        async let third: Void = list.refresh()
        _ = await (first, second, third)

        #expect(statusCommands(in: log).count == before + 2)
    }

    @Test func looksAtALimitedNumberOfRepositoriesAtOnce() async throws {
        let log = CommandLog()
        let list = RepositoryList(store: store)
        await list.connect(git: try await gitWithSlowStatus(log: log))
        for index in 0...RepositoryList.lookLimit {
            _ = try await list.add(folder: try await copyRepository(try await Fixture.repository("basic"), into: folder + "/\(index)"))
        }
        await list.refresh()

        let commands = statusCommands(in: log)
        let mostAtOnce = commands.map { command in
            commands.count { other in
                let running = other.duration.map { TimeInterval($0.components.seconds) + TimeInterval($0.components.attoseconds) / 1e18 } ?? 0
                return other.started <= command.started && command.started < other.started.addingTimeInterval(running)
            }
        }.max()
        #expect(mostAtOnce == RepositoryList.lookLimit)
        #expect(list.repositories.allSatisfy { $0.uncommittedFiles.count == 1 })
    }

    // MARK: Changes on disk

    @Test func seesChangesOnDiskWithoutBeingAsked() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        try await runGit("config", "user.name", "T", in: repository)
        try await runGit("config", "user.email", "t@example.com", in: repository)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        let listed = try #require(list.repositories.first)
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.session?.isWatching == true })
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.uncommittedFiles[repository] == 0 })

        try Data("new\n".utf8).write(to: URL(filePath: repository + "/new.txt"))
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.uncommittedFiles[repository] == 1 })
        #expect(listed.fileChanges[repository] != nil)

        // A commit moves the branch, which the row's commit and its count follow.
        let refsChange = listed.refsChange
        try await runGit("add", "new.txt", in: repository)
        try await runGit("commit", "--quiet", "-m", "New", in: repository)
        let head = try await runGit("rev-parse", "HEAD", in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.worktrees.first?.head?.hex == head && listed.uncommittedFiles[repository] == 0 })
        #expect(listed.refsChange > refsChange)

        // A new worktree is listed, counted and watched.
        let notes = folder + "/notes"
        try await runGit("worktree", "add", "--quiet", notes, "feature", in: repository)
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.uncommittedFiles[notes] == 0 })
        try Data("a\n".utf8).write(to: URL(filePath: notes + "/a.txt"))
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.uncommittedFiles[notes] == 1 })
        #expect(listed.uncommittedFiles[repository] == 0)
    }

    @Test func becomingActiveLooksOnlyAtWhatItCantWatch() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let log = CommandLog()
        let list = RepositoryList(store: store)
        await list.connect(git: try await TestGit.make(log: log))
        _ = try await list.add(folder: repository)
        let listed = try #require(list.repositories.first)
        #expect(await AgentTestSupport.eventually { listed.session?.isWatching == true })
        await list.refresh()
        let before = statusCommands(in: log).count

        await list.refreshUnwatched()
        #expect(statusCommands(in: log).count == before)
    }

    @Test func looksAddUp() {
        typealias Request = RepositoryList.LookRequest
        let files = Request(counts: ["/a"], asNewAs: 3)
        let refs = Request(counts: ["/b"], upstreams: true, asNewAs: 5)
        #expect(files.adding(refs) == Request(counts: ["/a", "/b"], upstreams: true, asNewAs: 5))
        #expect(files.isPaced)
        // Anything that has to look afresh makes the look afresh.
        #expect(files.adding(.everything) == .everything)
        #expect(!Request.everything.isPaced)
    }

    @Test func pacesLooksThatKeepComing() {
        let start = ContinuousClock.now
        #expect(ChangePacing.gap(afterLookFrom: start, to: start + .milliseconds(10)) == .milliseconds(500))
        #expect(ChangePacing.gap(afterLookFrom: start, to: start + .milliseconds(400)) == .milliseconds(800))
    }

    @Test func remembersWhichRepositoriesAreExpanded() async throws {
        let list = try await makeList()
        _ = try await list.add(folder: try await Fixture.repository("basic"))
        #expect(list.repositories.first?.isExpanded == false)
        list.setExpanded(true, try #require(list.repositories.first))
        #expect(try await makeList().repositories.first?.isExpanded == true)
    }

    /// A list with a collapsed repository that has a linked worktree, and that
    /// worktree's selection.
    private func listWithLinkedWorktree() async throws -> (RepositoryList, ListedRepository, WorktreeSelection) {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: repository)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        let listed = try #require(list.repositories.first)
        return (list, listed, WorktreeSelection(repository: listed.path, worktree: folder + "/notes"))
    }

    @Test func aCollapsedRepositoryRemembersTheWorktreesItKeeps() async throws {
        let (list, listed, notes) = try await listWithLinkedWorktree()
        list.keepShowing(notes)
        #expect(listed.keptWorktrees == [notes.worktree])
        #expect(try await makeList().repositories.first?.keptWorktrees == [notes.worktree])
    }

    @Test func expandingARepositoryForgetsTheWorktreesItKept() async throws {
        let (list, listed, notes) = try await listWithLinkedWorktree()
        list.keepShowing(notes)
        list.setExpanded(true, listed)
        list.setExpanded(false, listed)
        #expect(listed.keptWorktrees.isEmpty)
    }

    @Test func onlyACollapsedRepositoryKeepsALinkedWorktree() async throws {
        let (list, listed, notes) = try await listWithLinkedWorktree()
        list.keepShowing(listed.home)
        #expect(listed.keptWorktrees.isEmpty)
        list.setExpanded(true, listed)
        list.keepShowing(notes)
        #expect(listed.keptWorktrees.isEmpty)
    }

    @Test func readsAndRemembersWhoOwnsARepository() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        try await runGit("remote", "set-url", "origin", "git@github.com:acme/basic.git", in: repository)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        #expect(list.repositories.first?.owners == ["acme"])

        // It's known before the repository opens, so a repository that can't
        // be opened stays in its organization.
        let reopened = RepositoryList(store: store)
        #expect(reopened.repositories.first?.owners == ["acme"])
    }

    @Test func remembersEveryOwnerOfARepositoryWithoutAnOrigin() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        try await runGit("remote", "remove", "origin", in: repository)
        try await runGit("remote", "add", "work", "https://github.com/acme/basic.git", in: repository)
        try await runGit("remote", "add", "client", "https://me@dev.azure.com/northwind/basic/_git/basic", in: repository)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        #expect(list.repositories.first?.owners == ["northwind", "acme"])

        let reopened = RepositoryList(store: store)
        #expect(reopened.repositories.first?.owners == ["northwind", "acme"])
    }

    @Test func seesThatRemotesChanged() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        try await runGit("remote", "set-url", "origin", "https://github.com/acme/basic.git", in: repository)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        try await runGit("remote", "set-url", "origin", "https://github.com/northwind/basic.git", in: repository)
        await list.refresh()
        #expect(list.repositories.first?.owners == ["northwind"])
        try await runGit("remote", "add", "work", "https://github.com/acme/basic.git", in: repository)
        await list.refresh()
        #expect(list.repositories.first?.owners == ["northwind", "acme"])
        try await runGit("remote", "remove", "origin", in: repository)
        await list.refresh()
        #expect(list.repositories.first?.owners == ["acme"])
        try await runGit("remote", "remove", "work", in: repository)
        await list.refresh()
        #expect(list.repositories.first?.owners == [])
    }

    @Test func findsClonesBesideTheListedOnes() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder + "/git")
        let other = try await copyRepository(try await Fixture.repository("history") + "/single", into: folder + "/git")
        let elsewhere = try await copyRepository(try await Fixture.repository("history") + "/chain", into: folder + "/elsewhere")
        let list = try await makeList()
        #expect(await list.clonesToAdd().isEmpty)
        _ = try await list.add(folder: repository)
        #expect(await list.clonesToAdd().map(\.path) == [other])
        #expect(Set(await list.clonesToAdd(alsoLookingIn: [folder + "/elsewhere"]).map(\.path)) == [other, elsewhere])
        let foundBefore = await list.clonesToAdd()
        _ = try await list.add(folder: other)
        #expect(await list.clonesToAdd().isEmpty)
        // What the popover found before keeps out what's been added since.
        #expect(list.unlisted(foundBefore).isEmpty)
    }

    @Test func setsAsideAFileItCantRead() async throws {
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.file)

        let list = try await makeList()
        #expect(list.repositories.isEmpty)
        #expect(try Data(contentsOf: store.unreadableFile) == Data("not json".utf8))
        _ = try await list.add(folder: try await Fixture.repository("basic"))
        #expect(try await makeList().repositories.count == 1)
        #expect(try Data(contentsOf: store.unreadableFile) == Data("not json".utf8))
    }

    // MARK: The worktree a folder is in

    @Test func findsTheWorktreeAFolderIsIn() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        // Claude Code puts its worktrees inside the main checkout.
        try await runGit("worktree", "add", "--quiet", repository + "/.claude/worktrees/fix", "feature", in: repository)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        let main = WorktreeSelection(repository: repository + "/.git", worktree: repository)
        let fix = WorktreeSelection(repository: repository + "/.git", worktree: repository + "/.claude/worktrees/fix")

        #expect(list.worktree(containing: repository) == main)
        #expect(list.worktree(containing: repository + "/src/") == main)
        #expect(list.worktree(containing: repository + "/.claude/worktrees/fix") == fix)
        #expect(list.worktree(containing: repository + "/.claude/worktrees/fix/src") == fix)
        // A folder that only starts the same way is somewhere else.
        #expect(list.worktree(containing: repository + "-old") == nil)
        #expect(list.worktree(containing: folder) == nil)
        #expect(list.worktree(containing: "/") == nil)
    }

    @Test func comparesFoldersAsTheyReallyAre() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        let main = WorktreeSelection(repository: repository + "/.git", worktree: repository)

        // The temporary folder is behind a symbolic link, which the test's
        // folder is resolved past and an agent might not be.
        let unresolved = FileManager.default.temporaryDirectory.path(percentEncoded: false)
        let link = (unresolved.hasSuffix("/") ? unresolved : unresolved + "/") + (folder as NSString).lastPathComponent + "/basic"
        #expect(link != repository)
        #expect(list.worktree(containing: link + "/src") == main)
        #expect(list.worktree(containing: repository + "/src/../src/./") == main)
        try FileManager.default.createSymbolicLink(atPath: folder + "/shortcut", withDestinationPath: repository)
        #expect(list.worktree(containing: folder + "/shortcut/src") == main)
        // A folder that's been deleted is still in its worktree.
        #expect(list.worktree(containing: link + "/gone/deeper") == main)
    }

    @Test func aBareRepositoryOrAMissingWorktreeHoldsNothing() {
        let list = RepositoryList(listing: [
            ListedRepository(path: "/git/server.git", worktrees: [Worktree(path: "/git/server.git", isMain: true, isBare: true)]),
            ListedRepository(path: "/git/api/.git", worktrees: [
                Worktree(path: "/git/api", isMain: true),
                Worktree(path: "/git/api/old", isPrunable: true),
            ]),
        ])
        #expect(list.worktree(containing: "/git/server.git/hooks") == nil)
        #expect(list.worktree(containing: "/git/api/old/src")?.worktree == "/git/api")
    }
}

@discardableResult
func runGit(_ arguments: String..., in folder: String) async throws -> String {
    try await TestGit.make().text(GitCommand(arguments, in: folder))
}

/// Clones a test repository into `folder`, so a test can change or move it.
func copyRepository(_ repository: String, into folder: String) async throws -> String {
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let copy = folder + "/" + (repository as NSString).lastPathComponent
    try await runGit("clone", "--quiet", "--no-local", repository, copy, in: repository)
    return copy
}

/// Makes a new, empty folder for a test, and returns its real path.
func makeTemporaryFolder() throws -> String {
    let folder = FileManager.default.temporaryDirectory.appending(path: "roga-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let resolved = try #require(realpath(folder.path(percentEncoded: false), nil))
    defer { free(resolved) }
    let path = String(cString: resolved)
    // It goes when the test ends, in a suite that removes its folders, and
    // otherwise when the tests are done.
    TemporaryFolders.forThisTest.add(path)
    return path
}
