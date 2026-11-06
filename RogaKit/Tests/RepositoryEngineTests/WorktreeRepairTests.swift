import Foundation
import GitCore
import GitRunner
import TestSupport
import Testing
@testable import RepositoryEngine

/// Mending linked worktrees after a folder moved outside git, in a copy of the
/// `basic` repository with a linked worktree on `topic`. Each test reproduces
/// what moving a folder in Finder does.
@Suite(.timeLimit(.minutes(1)))
struct WorktreeRepairTests {
    struct Repository {
        var folder: String
        var main: String
        var linked: String
    }

    func repository() async throws -> Repository {
        let fixture = try await Fixture.repository("basic")
        let folder = try makeTemporaryFolder()
        let main = folder + "/main"
        let linked = folder + "/linked"
        try await runGit("clone", "--quiet", "--no-local", fixture, main, in: fixture)
        try await runGit("worktree", "add", "--quiet", "-b", "topic", linked, in: main)
        return Repository(folder: folder, main: main, linked: linked)
    }

    func move(_ from: String, to: String) throws {
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    /// Whether git works in a worktree, which it doesn't once its `.git` file
    /// points into a folder that's gone.
    func gitWorks(in worktree: String) async -> Bool {
        (try? await runGit("status", "--porcelain", in: worktree)) != nil
    }

    // MARK: A linked worktree moved

    @Test func aLinkedWorktreeThatMovedIsPrunableUntilItsRepairedFromItsNewFolder() async throws {
        let repository = try await repository()
        let moved = repository.folder + "/moved"
        try move(repository.linked, to: moved)
        let session = try await openSession(repository.main)
        let before = try await session.worktrees()
        #expect(before.map(\.path) == [repository.main, repository.linked])
        #expect(before.map(\.isPrunable) == [false, true])
        // git still works in the moved folder, because its own link is whole.
        #expect(await gitWorks(in: moved))

        try await session.repairWorktrees(movedTo: moved)
        let after = try await session.worktrees()
        #expect(after.map(\.path) == [repository.main, moved])
        #expect(after.map(\.isPrunable) == [false, false])
        #expect(after.last?.branch == "refs/heads/topic")
    }

    @Test func theCommandNamesTheFolderWhenThereIsOne() {
        #expect(WorktreeRepair.arguments(movedTo: "/code/moved") == ["worktree", "repair", "/code/moved"])
        #expect(WorktreeRepair.arguments() == ["worktree", "repair"])
    }

    @Test func refusesAFolderThatIsntALinkedWorktree() async throws {
        let repository = try await repository()
        try move(repository.linked, to: repository.folder + "/moved")
        let plain = repository.folder + "/plain"
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: false)
        let session = try await openSession(repository.main)

        let error = await #expect(throws: GitError.self) {
            try await session.repairWorktrees(movedTo: plain)
        }
        #expect(error?.command?.arguments == ["worktree", "repair", plain])
        #expect(try await session.worktrees().last?.isPrunable == true)
    }

    @Test func refusesAnotherRepository() async throws {
        let repository = try await repository()
        try move(repository.linked, to: repository.folder + "/moved")
        let other = try await copyRepository(try await Fixture.repository("basic"))
        let session = try await openSession(repository.main)

        await #expect(throws: GitError.self) {
            try await session.repairWorktrees(movedTo: other)
        }
    }

    @Test func anotherOfItsWorktreesMendsNothingWithoutComplaint() async throws {
        let repository = try await repository()
        let other = repository.folder + "/other"
        try await runGit("worktree", "add", "--quiet", "-b", "other", other, in: repository.main)
        try move(repository.linked, to: repository.folder + "/moved")
        let session = try await openSession(repository.main)

        try await session.repairWorktrees(movedTo: other)
        let worktrees = try await session.worktrees()
        #expect(worktrees.first { $0.path == repository.linked }?.isPrunable == true)
    }

    // MARK: The main worktree moved

    @Test func theMainWorktreeMovingBreaksEveryLinkedWorktreeQuietlyUntilItsRepaired() async throws {
        let repository = try await repository()
        let second = repository.folder + "/second"
        try await runGit("worktree", "add", "--quiet", "-b", "second", second, in: repository.main)
        let moved = repository.folder + "/moved"
        try move(repository.main, to: moved)
        let session = try await openSession(moved)

        // git lists them as if nothing were wrong, and fails in each of them.
        let before = try await session.worktrees()
        #expect(before.map(\.path) == [moved, repository.linked, second])
        #expect(before.allSatisfy { !$0.isPrunable })
        #expect(await !gitWorks(in: repository.linked))
        #expect(await !gitWorks(in: second))

        try await session.repairWorktrees()
        #expect(await gitWorks(in: repository.linked))
        #expect(await gitWorks(in: second))
        #expect(try await session.worktrees() == before)
    }

    @Test func repairingWithNothingBrokenChangesNothing() async throws {
        let repository = try await repository()
        let session = try await openSession(repository.main)
        let before = try await session.worktrees()
        try await session.repairWorktrees()
        #expect(try await session.worktrees() == before)
        #expect(await gitWorks(in: repository.linked))
    }

    // MARK: Both moved

    @Test func aLinkedWorktreeThatMovedWithItsRepositoryNeedsItsOwnFolder() async throws {
        let repository = try await repository()
        let main = repository.folder + "/main-moved"
        let linked = repository.folder + "/linked-moved"
        try move(repository.main, to: main)
        try move(repository.linked, to: linked)
        let session = try await openSession(main)

        // Repairing without a folder can't find it.
        try await session.repairWorktrees()
        #expect(try await session.worktrees().last?.isPrunable == true)
        #expect(await !gitWorks(in: linked))

        // Given its folder, git finds its way back by its name, and mends both
        // links.
        try await session.repairWorktrees(movedTo: linked)
        let worktrees = try await session.worktrees()
        #expect(worktrees.map(\.path) == [main, linked])
        #expect(worktrees.allSatisfy { !$0.isPrunable })
        #expect(await gitWorks(in: linked))
    }
}
