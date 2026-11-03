import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import YagaUI

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

        async let first: Void = list.refresh()
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
        _ = try await list.add(folder: other)
        #expect(await list.clonesToAdd().isEmpty)
    }

    @Test func picksTheWorktreeToShowInAnOrganization() async throws {
        let first = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        let second = try await copyRepository(try await Fixture.repository("history") + "/single", into: folder)
        try await runGit("worktree", "add", "--quiet", folder + "/notes", "feature", in: first)
        for repository in [first, second] {
            try await runGit("remote", "set-url", "origin", "git@github.com:acme/x.git", in: repository)
        }
        let list = try await makeList()
        let main = try await list.add(folder: first)
        _ = try await list.add(folder: second)
        let scope = SidebarScope.organization("acme")
        var place = SidebarPlace()

        // The first time, it's the first repository's main worktree.
        #expect(list.selectionToShow(in: scope, place: place, current: nil) == main)

        // After that, it's where the window was, for as long as that's there.
        let notes = WorktreeSelection(repository: first + "/.git", worktree: folder + "/notes")
        place.record(notes, in: list.groups)
        #expect(list.selectionToShow(in: scope, place: place, current: nil) == notes)
        try await runGit("worktree", "remove", folder + "/notes", in: first)
        await list.refresh()
        #expect(list.selectionToShow(in: scope, place: place, current: nil) == main)

        // A window that's already there stays, and All never moves a window.
        let inSecond = WorktreeSelection(repository: second + "/.git", worktree: second)
        #expect(list.selectionToShow(in: scope, place: SidebarPlace(), current: inSecond) == inSecond)
        #expect(list.selectionToShow(in: .all, place: place, current: nil) == nil)
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
    let folder = FileManager.default.temporaryDirectory.appending(path: "yaga-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let resolved = try #require(realpath(folder.path(percentEncoded: false), nil))
    defer { free(resolved) }
    return String(cString: resolved)
}
