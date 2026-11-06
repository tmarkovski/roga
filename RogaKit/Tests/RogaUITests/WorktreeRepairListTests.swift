import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// Finding worktrees again after their folders moved outside git: the list
/// following a repository that moved and mending its linked worktrees, and Locate…
/// on a linked worktree whose folder is missing. Each starts from a copy of the
/// `basic` repository with a linked worktree on `topic`.
@Suite(.timeLimit(.minutes(1)), .removesTemporaryFolders)
struct WorktreeRepairListTests {
    let folder: String
    let store: RepositoryStore

    init() throws {
        folder = try makeTemporaryFolder()
        store = RepositoryStore(file: URL(filePath: folder + "/support/repositories.json"))
    }

    /// A list read from the store, with every repository opened and looked at.
    func makeList() async throws -> RepositoryList {
        let list = RepositoryList(store: store)
        await list.connect(git: try await TestGit.make())
        return list
    }

    /// The main worktree's folder, and the linked worktree's.
    func repository() async throws -> (main: String, linked: String) {
        let main = try await copyRepository(try await Fixture.repository("basic"), into: folder + "/code")
        let linked = folder + "/code/topic"
        try await runGit("worktree", "add", "--quiet", "-b", "topic", linked, in: main)
        return (main, linked)
    }

    func gitWorks(in worktree: String) async -> Bool {
        (try? await runGit("status", "--porcelain", in: worktree)) != nil
    }

    func move(_ from: String, to: String) throws {
        try FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    // MARK: The repository moved

    @Test func followsARepositoryThatMovedAndMendsItsWorktrees() async throws {
        let (main, linked) = try await repository()
        _ = try await makeList().add(folder: main)
        let moved = folder + "/elsewhere/basic"
        try move(main, to: moved)
        #expect(await !gitWorks(in: linked))

        let list = try await makeList()
        let listed = try #require(list.repositories.first)
        #expect(listed.path == moved + "/.git")
        #expect(listed.worktrees.map(\.path) == [moved, linked])
        #expect(await gitWorks(in: linked))
        // The look that counts uncommitted files could run git there.
        #expect(listed.uncommittedFiles[linked] == 0)
    }

    @Test func followsARepositoryThatMovesWhileItsListed() async throws {
        let (main, linked) = try await repository()
        let list = try await makeList()
        _ = try await list.add(folder: main)
        let moved = folder + "/elsewhere/basic"
        try move(main, to: moved)

        // The first look after the move finds it where its bookmark says, rather
        // than calling it missing until the one after.
        await list.refresh()
        let listed = try #require(list.repositories.first)
        #expect(listed.path == moved + "/.git")
        #expect(listed.session != nil)
        #expect(await gitWorks(in: linked))
    }

    @Test func locatingARepositoryMendsItsWorktrees() async throws {
        let (main, linked) = try await repository()
        let list = try await makeList()
        _ = try await list.add(folder: main)
        // A copy, so that the bookmark doesn't find it, and the user has to.
        let copy = folder + "/elsewhere/basic"
        try FileManager.default.createDirectory(atPath: folder + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: main, toPath: copy)
        try FileManager.default.removeItem(atPath: main)
        await list.refresh()
        let missing = try #require(list.repositories.first)
        guard case .missing = missing.state else {
            Issue.record("The repository is \(missing.state), not missing")
            return
        }

        let selection = try await list.locate(missing, at: copy)
        let located = try #require(list.repository(at: selection.repository))
        #expect(await !gitWorks(in: linked))
        try await list.repairWorktrees(of: located)
        #expect(await gitWorks(in: linked))
        #expect(try await runGit("rev-parse", "--git-common-dir", in: linked) == copy + "/.git")
    }

    // MARK: A linked worktree moved

    @Test func locatesALinkedWorktreeThatMoved() async throws {
        let (main, linked) = try await repository()
        let list = try await makeList()
        _ = try await list.add(folder: main)
        let moved = folder + "/agents/topic"
        try move(linked, to: moved)
        await list.refresh()
        let repository = try #require(list.repositories.first)
        let missing = try #require(repository.worktrees.last)
        #expect(missing.isPrunable)

        let selection = try await list.repair(missing, in: repository, movedTo: moved)
        #expect(selection == WorktreeSelection(repository: repository.path, worktree: moved))
        #expect(repository.worktrees.map(\.path) == [main, moved])
        #expect(repository.worktrees.allSatisfy { !$0.isPrunable })
        #expect(list.resolve(selection) == selection)
    }

    @Test func aCollapsedRepositoryGoesOnShowingAWorktreeItFound() async throws {
        let (main, linked) = try await repository()
        let list = try await makeList()
        _ = try await list.add(folder: main)
        let repository = try #require(list.repositories.first)
        list.keepShowing(WorktreeSelection(repository: repository.path, worktree: linked))
        let moved = folder + "/agents/topic"
        try move(linked, to: moved)
        await list.refresh()

        _ = try await list.repair(try #require(repository.worktrees.last), in: repository, movedTo: moved)
        #expect(repository.keptWorktrees == [moved])
    }

    @Test func anotherOfItsWorktreesIsntTheOneThatMoved() async throws {
        let (main, linked) = try await repository()
        let other = folder + "/code/other"
        try await runGit("worktree", "add", "--quiet", "-b", "other", other, in: main)
        let list = try await makeList()
        _ = try await list.add(folder: main)
        try move(linked, to: folder + "/agents/topic")
        await list.refresh()
        let repository = try #require(list.repositories.first)
        let missing = try #require(repository.worktrees.first { $0.path == linked })

        await #expect(throws: RepositoryListError.self) {
            try await list.repair(missing, in: repository, movedTo: other)
        }
        #expect(repository.worktrees.first { $0.path == linked }?.isPrunable == true)
    }

    // MARK: What the sidebar says

    @Test func saysWhatGitSaidWhenTheFolderIsntAWorktree() async throws {
        let (main, linked) = try await repository()
        let list = try await makeList()
        _ = try await list.add(folder: main)
        try move(linked, to: folder + "/agents/topic")
        let plain = folder + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: false)
        await list.refresh()
        let repository = try #require(list.repositories.first)
        let missing = try #require(repository.worktrees.last)

        let model = WorktreeRepairModel()
        var selected: [WorktreeSelection] = []
        model.repair(missing, in: repository, movedTo: plain, list: list) { selected.append($0) }
        await model.running?.value
        #expect(selected.isEmpty)
        let failure = try #require(model.failure)
        #expect(failure.title == "Can't repair the worktree for topic")
        #expect(failure.command == ["worktree", "repair", plain])
        #expect(failure.said?.isEmpty == false)
        let dialog = try #require(model.dialog)
        #expect(dialog.terminal.first == .ran(["worktree", "repair", plain]))
        dialog.dismiss()
        #expect(model.failure == nil)
    }

    @Test func saysSoWhenTheFolderIsAnotherWorktree() throws {
        let missing = Worktree(path: "/code/topic", head: ObjectID(hex: "86b3386aa0000000000000000000000000000000"), branch: "refs/heads/topic", isPrunable: true)
        let failure = WorktreeRepairModel.failure(repairing: missing, movedTo: "/code/other", error: RepositoryListError.notTheWorktree)
        #expect(failure.summary == "other is another worktree, so the folder for topic is still missing.")
        #expect(failure.said == nil)
        #expect(failure.command == ["worktree", "repair", "/code/other"])
    }

    @Test func findsWhereAMissingFolderWas() throws {
        try FileManager.default.createDirectory(atPath: folder + "/agents", withIntermediateDirectories: false)
        #expect(nearestExistingFolder(above: folder + "/agents/gone/topic") == folder + "/agents")
        #expect(nearestExistingFolder(above: folder + "/agents/topic") == folder + "/agents")
    }
}
