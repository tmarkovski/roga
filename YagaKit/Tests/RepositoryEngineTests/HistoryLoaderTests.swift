import CommitGraph
import Foundation
import GitCore
import TestSupport
import Testing
@testable import RepositoryEngine

@Suite(.timeLimit(.minutes(1)))
struct HistoryLoaderTests {
    @Test(arguments: Fixture.History.allCases, [HistoryOrder.Sort.topological, .date])
    func ordersLikeGit(_ variant: Fixture.History, sort: HistoryOrder.Sort) async throws {
        let repository = try await variant.repository()
        let history = try #require(try await loadHistory(try await openSession(repository), sort: sort).last)
        #expect(history.isComplete)
        #expect(history.readCommitGraphFiles)
        #expect(history.sort == sort)
        #expect(history.ids == (try await gitOrder(sort, in: repository)))
    }

    @Test func yieldsTheFirstRowsFirst() async throws {
        let session = try await openSession(try await Fixture.History.single.repository())
        let snapshots = try await loadHistory(session, firstRows: 10)
        try #require(snapshots.count == 2)
        #expect(snapshots[0].rows.count == 10)
        #expect(!snapshots[0].isComplete)
        #expect(snapshots[1].isComplete)
        #expect(Array(snapshots[1].rows.prefix(10)) == snapshots[0].rows)
    }

    @Test func yieldsOnceWhenTheFirstRowsAreAll() async throws {
        let snapshots = try await loadHistory(try await openSession(try await Fixture.repository("basic")), firstRows: 10)
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.isComplete == true)
    }

    @Test func addsCommitsNewerThanTheFile() async throws {
        let history = try #require(try await loadHistory(try await openSession(try await Fixture.History.stale.repository())).last)
        #expect(history.readCommitGraphFiles)
        #expect(history.graph.count > history.graph.storedCount)
        #expect(history.rows.count == history.graph.count)
    }

    @Test(arguments: [HistoryOrder.Sort.topological, .date])
    func asksGitWhenThereIsNoCommitGraph(sort: HistoryOrder.Sort) async throws {
        let repository = try await Fixture.repository("basic")
        let history = try #require(try await loadHistory(try await openSession(repository), sort: sort).last)
        #expect(!history.readCommitGraphFiles)
        #expect(history.ids == (try await gitOrder(sort, in: repository)))
    }

    @Test func ignoresTheFilesInAShallowRepository() async throws {
        // Fetching with a depth makes a repository shallow even when it has
        // every commit, so its commit-graph file has parents git now hides.
        let repository = try await copyRepository(try await Fixture.History.single.repository())
        try await runGit("commit-graph", "write", "--reachable", in: repository)
        try await runGit("fetch", "--quiet", "--depth=3", "origin", in: repository)

        let session = try await openSession(repository)
        #expect(session.location.isShallow)
        let history = try #require(try await loadHistory(session).last)
        #expect(!history.readCommitGraphFiles)
        #expect(history.ids == (try await gitOrder(.topological, in: repository)))
    }

    @Test func ignoresTheFilesWhenReplaceRefsChangeParents() async throws {
        let repository = try await copyRepository(try await Fixture.History.single.repository())
        try await runGit("commit-graph", "write", "--reachable", in: repository)
        try await runGit("replace", "--graft", "main~5", "main~20", in: repository)

        let history = try #require(try await loadHistory(try await openSession(repository)).last)
        #expect(!history.readCommitGraphFiles)
        #expect(history.ids == (try await gitOrder(.topological, in: repository)))
    }

    @Test func ignoresDamagedFiles() async throws {
        let repository = try await copyRepository(try await Fixture.History.single.repository())
        try await runGit("commit-graph", "write", "--reachable", in: repository)
        let file = repository + "/.git/objects/info/commit-graph"
        try FileManager.default.removeItem(atPath: file)
        try Data(repeating: 0, count: 100).write(to: URL(filePath: file))

        let history = try #require(try await loadHistory(try await openSession(repository)).last)
        #expect(!history.readCommitGraphFiles)
        #expect(history.ids == (try await gitOrder(.topological, in: repository)))
    }

    @Test func showsRefsAtTheirCommits() async throws {
        let history = try #require(try await loadHistory(try await openSession(try await Fixture.repository("basic"))).last)
        func refs(at id: String) throws -> [String] {
            let commit = try #require(ObjectID(hex: id))
            let position = try #require(history.graph.position(of: commit))
            return history.refsByCommit[position]?.map(\.name) ?? []
        }
        #expect(history.refs.currentBranch == "refs/heads/main")
        #expect(history.head == history.graph.position(of: ObjectID(hex: Fixture.Basic.main)!))
        #expect(try refs(at: Fixture.Basic.main) == ["refs/heads/main"])
        #expect(try refs(at: Fixture.Basic.feature) == ["refs/heads/feature"])
        #expect(try refs(at: Fixture.Basic.mainHistory[2]) == ["refs/tags/v0.1"])
        #expect(try refs(at: Fixture.Basic.mainHistory[1]) == [])
    }

    @Test func ordersTheRefsAtACommit() async throws {
        // A clone has remote branches and origin/HEAD, which is left out
        // because origin/main is shown already.
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        try await runGit("branch", "a-branch", in: repository)
        try await runGit("tag", "v9", in: repository)

        let history = try #require(try await loadHistory(try await openSession(repository)).last)
        let head = try #require(history.head)
        #expect(history.refsByCommit[head]?.map(\.name) == [
            "refs/heads/main", "refs/heads/a-branch", "refs/remotes/origin/main", "refs/tags/v9",
        ])
    }

    @Test func findsADetachedHead() async throws {
        let repository = try await copyRepository(try await Fixture.repository("basic"))
        try await runGit("switch", "--quiet", "--detach", "main~1", in: repository)

        let history = try #require(try await loadHistory(try await openSession(repository)).last)
        #expect(history.refs.currentBranch == nil)
        #expect(history.head == history.graph.position(of: ObjectID(hex: Fixture.Basic.mainHistory[1])!))
    }

    @Test func loadsARepositoryWithoutCommits() async throws {
        let repository = try makeTemporaryFolder()
        try await runGit("init", "--quiet", in: repository)
        let snapshots = try await loadHistory(try await openSession(repository))
        #expect(snapshots.count == 1)
        #expect(snapshots.first?.rows.isEmpty == true)
        #expect(snapshots.first?.isComplete == true)
        #expect(snapshots.first?.head == nil)
    }
}
