import CommitGraph
import GitCore
import TestSupport
import Testing
@testable import RepositoryEngine

@Suite(.timeLimit(.minutes(1)))
struct HistoryReplayLoadingTests {
    /// Takes the commit `name` points to from the history the session loaded.
    private func load(_ name: String, range: HistoryReplay.CommitRange = .all) async throws -> HistoryReplay {
        let repository = try await Fixture.repository("replay")
        let session = try await openSession(repository)
        let history = try #require(try await loadHistory(session).last)
        let tip = try #require(history.refs.refs.first { Ref.shortName($0.name) == name }?.peeled)
        return try await session.replay(
            of: try #require(history.graph.position(of: tip)),
            in: history.graph,
            range: range,
            mainLineName: name,
            length: 75
        )
    }

    @Test func loadsTheTextEachBranchIsNamedFrom() async throws {
        let replay = try await load("main")
        let login = try #require(replay.branches.first { $0.name == "add-login" })
        #expect(login.pullRequest == 1)
        // The title comes from the first line of the merge's body.
        #expect(login.title == "Add a login page")
        #expect(replay.commits.last?.subject == "Release 1.0")
    }

    @Test func fitsTheLengthItIsGiven() async throws {
        let replay = try await load("main")
        // Half a second follows the last commit.
        #expect(replay.playEnd <= 75.5)
        #expect(replay.commits.first?.commitTime == 1_767_225_600)
    }

    @Test func readsOnlyAMergesBody() async throws {
        let repository = try await Fixture.repository("replay")
        let session = try await openSession(repository)
        let history = try #require(try await loadHistory(session).last)
        let tip = try #require(history.refs.refs.first { Ref.shortName($0.name) == "main" }?.peeled)
        let positions = try HistoryReplay.commits(in: history.graph, from: try #require(history.graph.position(of: tip)), range: .all)
        let messages = try await session.replayMessages(for: positions, in: history.graph)
        #expect(messages.count == positions.count)
        let bodies = messages.filter { !$0.body.isEmpty }.map(\.subject)
        #expect(bodies.count == 3)
        #expect(bodies.allSatisfy { $0.hasPrefix("Merge pull request") })
    }
}
