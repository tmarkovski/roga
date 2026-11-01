import GitCore
import TestSupport
import Testing
@testable import CommitGraph

@Suite(.timeLimit(.minutes(1)))
struct HistoryOrderTests {
    /// Sets of tips to order from, as names git understands. They include
    /// tips with the same commit time in both orders, an annotated tag on the
    /// same commit as a branch, and repeated tips.
    static let tipSets: [[String]] = [
        ["main"],
        ["future"],
        ["topic-b", "topic-c", "topic-d"],
        ["topic-d", "topic-c", "topic-b"],
        ["main", "future", "old-feature", "pages", "topic-a", "topic-b", "topic-c", "topic-d", "base", "v1.0"],
        ["v1.0", "pages", "main", "pages", "topic-a"],
    ]

    @Test(arguments: Fixture.History.allCases, [HistoryOrder.Sort.date, .topological])
    func ordersLikeGit(_ history: Fixture.History, _ sort: HistoryOrder.Sort) async throws {
        let repository = try await history.repository()
        let graph = try await history.graph()
        for names in Self.tipSets {
            let tips = try await resolve(names, in: repository).map { try #require(graph.position(of: $0)) }
            var order = try HistoryOrder(graph: graph, tips: tips, sort: sort)
            let rows = try order.next(Int.max).map(graph.id(at:))
            #expect(rows == (try await gitOrder(sort, from: names, in: repository)), "from \(names)")
            #expect(order.isFinished)
        }
    }

    /// Without generation numbers, the walk counts all of history before the
    /// first commit, and still has to give the same order.
    @Test(arguments: [HistoryOrder.Sort.date, .topological])
    func ordersLikeGitWithoutGenerationNumbers(_ sort: HistoryOrder.Sort) async throws {
        let repository = try await Fixture.History.single.repository()
        var graph = try await Fixture.History.single.graph()
        graph.generations = .none
        let names = Self.tipSets[4]
        let tips = try await resolve(names, in: repository).map { try #require(graph.position(of: $0)) }
        var order = try HistoryOrder(graph: graph, tips: tips, sort: sort)
        #expect(order.countedCommitsSoFar == graph.count)
        let rows = try order.next(Int.max).map(graph.id(at:))
        #expect(rows == (try await gitOrder(sort, from: names, in: repository)))
    }

    /// The first rows of a long, straight history only need the commits just
    /// below them.
    @Test(arguments: [HistoryOrder.Sort.date, .topological])
    func countsOnlyWhatTheFirstRowsNeed(_ sort: HistoryOrder.Sort) async throws {
        let repository = try await Fixture.History.single.repository()
        let graph = try await Fixture.History.single.graph()
        let tips = try await resolve(["base"], in: repository).map { try #require(graph.position(of: $0)) }
        var order = try HistoryOrder(graph: graph, tips: tips, sort: sort)
        let rows = try order.next(10).map(graph.id(at:))
        #expect(rows == Array(try await gitOrder(sort, from: ["base"], in: repository).prefix(10)))
        #expect(order.countedCommitsSoFar <= 11)
        #expect(!order.isFinished)
    }

    @Test func handsOutRowsInBatches() async throws {
        let repository = try await Fixture.History.chain.repository()
        let graph = try await Fixture.History.chain.graph()
        let tips = try await resolve(Self.tipSets[4], in: repository).map { try #require(graph.position(of: $0)) }
        var all = try HistoryOrder(graph: graph, tips: tips, sort: .date)
        var batched = try HistoryOrder(graph: graph, tips: tips, sort: .date)
        var rows: [CommitGraph.Position] = []
        while !batched.isFinished {
            rows += try batched.next(7)
        }
        #expect(rows == (try all.next(Int.max)))
        #expect(try batched.next() == nil)
    }

    @Test func ordersNothingWithoutTips() async throws {
        var order = try HistoryOrder(graph: try await Fixture.History.single.graph(), tips: [], sort: .date)
        #expect(order.isFinished)
        #expect(try order.next() == nil)
        #expect(try order.next(10) == [])
    }
}
