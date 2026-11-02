import GitCore
import TestSupport
import Testing
@testable import RepositoryEngine

@Suite(.timeLimit(.minutes(1)))
struct RepositorySessionTests {
    @Test func readsCommits() async throws {
        let session = try await openSession(try await Fixture.repository("basic"))
        let ids = try [
            Fixture.Basic.main,
            Fixture.Basic.feature,
            // A tree, and an ID the repository doesn't have.
            Fixture.Basic.mainTree,
            String(repeating: "0", count: 40),
        ].map { try #require(ObjectID(hex: $0)) }
        let commits = try await session.commits(ids)

        try #require(commits.count == 4)
        let main = try #require(commits[0])
        #expect(main.id == ids[0])
        #expect(main.subject == "Change the app")
        #expect(main.message == "Change the app\n\nThe body says why.\n")
        #expect(main.author == Signature(name: "Ana Kovač", email: "ana@example.com", time: 1767434400, timeZoneOffset: 0))
        #expect(main.parents == [ObjectID(hex: Fixture.Basic.mainHistory[1])])
        #expect(commits[1]?.author.name == "Sam Lee")
        #expect(commits[2] == nil)
        #expect(commits[3] == nil)
    }

    @Test func refusesCommitsOnceClosed() async throws {
        let session = try await openSession(try await Fixture.repository("basic"))
        await session.close()
        await #expect(throws: (any Error).self) {
            try await session.commits([try #require(ObjectID(hex: Fixture.Basic.main))])
        }
    }
}
