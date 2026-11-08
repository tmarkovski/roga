import CommitGraph
import Foundation
import GitRunner
import RepositoryEngine

/// Measures working out the replay of `HEAD` (decision 62): listing the
/// commits in the range, reading their text, and the part that decides the
/// main line and the branches, which walks both sides of every merge.
struct ReplayBenchmark {
    var repository: String
    var days: Int?
    var runs = 5

    init(arguments: [String]) throws {
        var remaining = arguments[...]
        var repository: String?
        while let argument = remaining.popFirst() {
            switch argument {
            case "--days":
                guard let value = remaining.popFirst().flatMap(Int.init), value > 0 else {
                    throw UsageError(description: "--days takes a positive number")
                }
                days = value
            case "--runs":
                guard let value = remaining.popFirst().flatMap(Int.init), value > 0 else {
                    throw UsageError(description: "--runs takes a positive number")
                }
                runs = value
            default:
                repository = argument
            }
        }
        guard let repository else { throw UsageError(description: "Name a repository") }
        self.repository = repository
    }

    func run() async throws {
        let git = Git(installation: try await GitInstallation.locate())
        let session = try await RepositorySession.open(containing: repository, git: git)
        defer { Task { await session.close() } }

        var last: History?
        for try await history in session.history(sort: .date) { last = history }
        guard let history = last, let tip = history.head else {
            throw UsageError(description: "\(repository) has no commits")
        }
        let graph = history.graph
        let newest = graph.commitTime(at: tip)
        let range: HistoryReplay.CommitRange = days.map { .since(time: newest - Int64($0) * 86_400) } ?? .all

        let clock = ContinuousClock()
        var start = clock.now
        let positions = try HistoryReplay.commits(in: graph, from: tip, range: range)
        let listing = clock.now - start

        start = clock.now
        let messages = try await session.replayMessages(for: positions, in: graph)
        let reading = clock.now - start

        var times: [Duration] = []
        var replay: HistoryReplay?
        for _ in 0..<runs {
            start = clock.now
            replay = try HistoryReplay(
                graph: graph,
                tip: tip,
                positions: positions,
                messages: messages,
                mainLineName: "main",
                length: 75
            )
            times.append(clock.now - start)
        }
        times.sort()

        print("\(repository), \(days.map { "the last \($0) days" } ?? "all of history")")
        print("\(positions.count) commits of \(graph.count), \(replay?.branches.count ?? 0) branches, \(replay?.farthestLane ?? 0) lanes each way")
        print("listing the range: \(listing)")
        print("reading the text: \(reading)")
        print("working it out: \(times[times.count / 2]) (median of \(runs))")
    }
}
