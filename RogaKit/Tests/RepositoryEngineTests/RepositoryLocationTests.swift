import GitCore
import TestSupport
import Testing
@testable import RepositoryEngine

@Suite(.timeLimit(.minutes(1)))
struct RepositoryLocationTests {
    @Test func findsAWorktree() async throws {
        let repository = try await Fixture.repository("basic")
        let location = try await RepositoryLocation.find(containing: repository, git: try await TestGit.make())
        #expect(location == RepositoryLocation(
            worktree: repository,
            commonDirectory: repository + "/.git",
            objectsFolder: repository + "/.git/objects",
            format: .sha1,
            isShallow: false
        ))
        #expect(location.directory == repository)
        #expect(location.name == "basic")
    }

    @Test func findsTheRepositoryFromAFolderInside() async throws {
        let repository = try await Fixture.repository("basic")
        let git = try await TestGit.make()
        let fromInside = try await RepositoryLocation.find(containing: repository + "/src", git: git)
        #expect(fromInside == (try await RepositoryLocation.find(containing: repository, git: git)))
    }

    @Test func findsTheObjectFormat() async throws {
        let repository = try await Fixture.History.sha256.repository()
        let location = try await RepositoryLocation.find(containing: repository, git: try await TestGit.make())
        #expect(location.format == .sha256)
    }

    @Test func findsABareRepository() async throws {
        let folder = try makeTemporaryFolder()
        let bare = folder + "/basic.git"
        try await runGit("clone", "--quiet", "--bare", try await Fixture.repository("basic"), bare, in: folder)
        let location = try await RepositoryLocation.find(containing: bare, git: try await TestGit.make())
        #expect(location.worktree == nil)
        #expect(location.commonDirectory == bare)
        #expect(location.directory == bare)
        #expect(location.name == "basic")
    }

    @Test(arguments: [false, true])
    func explainsWhyAFolderCantBeOpened(exists: Bool) async throws {
        let folder = try makeTemporaryFolder() + (exists ? "" : "/missing")
        await #expect {
            try await RepositoryLocation.find(containing: folder, git: try await TestGit.make())
        } throws: { error in
            guard case RepositoryError.cannotOpen(let path, let message) = error else { return false }
            return path == folder && !message.isEmpty
        }
    }
}
