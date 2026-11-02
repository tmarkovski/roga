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

    @Test func remembersWhichRepositoriesAreExpanded() async throws {
        let list = try await makeList()
        _ = try await list.add(folder: try await Fixture.repository("basic"))
        list.setExpanded(false, try #require(list.repositories.first))
        #expect(try await makeList().repositories.first?.isExpanded == false)
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
