import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

@Suite(.timeLimit(.minutes(1)))
struct CloneTests {
    let folder: String
    let store: RepositoryStore

    init() throws {
        folder = try makeTemporaryFolder()
        store = RepositoryStore(file: URL(filePath: folder + "/support/repositories.json"))
    }

    func makeList(git: Git? = nil) async throws -> RepositoryList {
        let list = RepositoryList(store: store)
        let git = if let git { git } else { try await TestGit.make() }
        await list.connect(git: git)
        return list
    }

    @Test func clonesARepositoryAndListsIt() async throws {
        let source = try await Fixture.repository("basic")
        let list = try await makeList()
        let request = CloneRequest(url: "file://" + source, folder: folder, name: "basic-clone")
        let selection = try await list.clone(request)
        #expect(selection == WorktreeSelection(repository: folder + "/basic-clone/.git", worktree: folder + "/basic-clone"))
        let listed = try #require(list.repositories.first)
        #expect(listed.session != nil)
        #expect(listed.cloning == nil)
        // It's saved once it's done.
        #expect(RepositoryList(store: store).repositories.map(\.path) == [folder + "/basic-clone/.git"])
    }

    @Test func aRefusedCloneLeavesNothingListed() async throws {
        let list = try await makeList()
        let request = CloneRequest(url: folder + "/nowhere", folder: folder, name: "nowhere")
        await #expect(throws: GitError.self) { try await list.clone(request) }
        #expect(list.repositories.isEmpty)
        #expect(RepositoryList(store: store).repositories.isEmpty)
    }

    @Test func cancellingACloneTakesItsRowAway() async throws {
        // The ext transport runs a command in place of a server, here one that
        // never answers, so the clone waits.
        let git = Git(
            installation: try await TestGit.installation(),
            environment: TestGit.isolatedEnvironment.merging(["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.ext.allow", "GIT_CONFIG_VALUE_0": "always"]) { $1 }
        )
        let list = try await makeList(git: git)
        let request = CloneRequest(url: "ext::sleep 30", folder: folder, name: "slow", recursesSubmodules: false)
        let cloning = Task { try await list.clone(request) }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !FileManager.default.fileExists(atPath: request.destination), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let listed = try #require(list.repositories.first)
        #expect(listed.cloning?.request == request)
        // A running clone isn't saved.
        #expect(RepositoryList(store: store).repositories.isEmpty)

        list.cancelClone(listed)
        #expect(listed.cloning?.isCancelling == true)
        await #expect(throws: CancellationError.self) { try await cloning.value }
        #expect(list.repositories.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: request.destination))
    }

    @Test func findsARepositoryByAnyURLForIt() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder + "/code")
        try await runGit("remote", "set-url", "origin", "git@github.com:acme/basic.git", in: repository)
        let list = try await makeList()
        _ = try await list.add(folder: repository)
        #expect(list.repository(withRemote: "https://github.com/acme/basic") === list.repositories.first)
        #expect(list.repository(withRemote: "https://github.com/acme/other") == nil)
        #expect(list.repository(withRemote: "") == nil)
    }

    @Test func offersTheFolderMostRepositoriesAreInFirst() {
        let list = RepositoryList(listing: [
            ListedRepository(path: "/Users/me/work/api/.git"),
            ListedRepository(path: "/Users/me/git/a/.git"),
            ListedRepository(path: "/Users/me/git/b/.git"),
        ])
        #expect(list.cloneFolders() == ["/Users/me/git", "/Users/me/work"])
        #expect(list.cloneFolders(alsoLookingIn: ["/Volumes/Disk", "/Users/me/work"]) == ["/Users/me/git", "/Users/me/work", "/Volumes/Disk"])
    }

    @Test func theNameFollowsTheURLUntilItsTyped() {
        var form = CloneFormState()
        form.setURL("https://github.com/acme/api.git")
        #expect(form.name == "api")
        form.setName("api-2")
        form.setURL("https://github.com/acme/web")
        #expect(form.name == "api-2")
        // Clearing it goes back to the URL's.
        form.setName("")
        #expect(form.name == "web")
        form.setURL("git@github.com:acme/docs.git")
        #expect(form.name == "docs")
    }

    @Test func theRowSaysHowFarAlongItIs() {
        #expect(CloneLine(progress: CloneProgress()).words == "Cloning…")
        let receiving = CloneLine(progress: CloneProgress(step: "receiving objects", percent: 42))
        #expect(receiving.words == "Cloning · receiving objects")
        #expect(receiving.end == "42%")
        #expect(receiving.spoken == "Cloning · receiving objects 42%")
        #expect(CloneLine(progress: CloneProgress(step: "resolving deltas", submodule: "vendor/lib")).words == "Cloning vendor/lib · resolving deltas")
        let cancelling = CloneLine(progress: CloneProgress(step: "receiving objects", percent: 42), isCancelling: true)
        #expect(cancelling.words == "Cancelling clone…")
        #expect(cancelling.end == nil)
    }
}
