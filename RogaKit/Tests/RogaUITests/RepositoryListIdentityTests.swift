import Foundation
import GitCore
import GitRunner
import RepositoryEngine
import TestSupport
import Testing
@testable import RogaUI

/// The sidebar's list reading who each repository's commits go out as, with
/// its look, and changing it (decision 103).
@Suite(.timeLimit(.minutes(1)))
struct RepositoryListIdentityTests {
    let folder: String
    let store: RepositoryStore

    init() throws {
        folder = try makeTemporaryFolder()
        store = RepositoryStore(file: URL(filePath: folder + "/support/repositories.json"))
    }

    func listed(email: String? = "sam@oss.example") async throws -> (RepositoryList, ListedRepository, String) {
        let repository = try await copyRepository(try await Fixture.repository("basic"), into: folder)
        if let email {
            try await runGit("config", "user.email", email, in: repository)
        }
        let list = RepositoryList(store: store)
        await list.connect(git: try await TestGit.make())
        _ = try await list.add(folder: repository)
        let listed = try #require(list.repositories.first)
        return (list, listed, repository)
    }

    @Test func readsItWithTheFirstLook() async throws {
        let (list, listed, _) = try await listed()
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.identity != nil })
        #expect(listed.identity?.shownEmail == "sam@oss.example")
        #expect(listed.identity?.email?.origin.scope == .local)
        // The tests keep the user's global config out, so there's no
        // identity outside the repository.
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { list.defaultIdentity != nil })
        #expect(list.defaultIdentity == CommitIdentity())
    }

    @Test func readsItAgainOnceItsChanged() async throws {
        let (list, listed, _) = try await listed(email: nil)
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.identity != nil })
        #expect(listed.identity?.problem == .noEmail)

        try await list.changeIdentity([.set(.email, "sam@rivera.dev", in: .repository)], of: listed)
        #expect(listed.identity?.shownEmail == "sam@rivera.dev")
        #expect(listed.identity?.problem == nil)
    }

    @Test func seesThatTheRepositorysConfigChanged() async throws {
        let (list, listed, repository) = try await listed()
        // A change before the watcher starts would go unseen.
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.session?.isWatching == true && listed.identity != nil })
        try await runGit("config", "user.email", "sam@elsewhere.example", in: repository)
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.identity?.shownEmail == "sam@elsewhere.example" })
        _ = list
    }

    @Test func saysWhatGitRefused() async throws {
        let (list, listed, _) = try await listed()
        #expect(await AgentTestSupport.eventually(within: .seconds(20)) { listed.identity != nil })
        // The tests' global config is /dev/null, which git can't write.
        await #expect(throws: (any Error).self) {
            try await list.changeIdentity([.set(.name, "Sam", in: .everyRepository)], of: listed)
        }
        #expect(listed.identity?.shownEmail == "sam@oss.example")
    }
}
