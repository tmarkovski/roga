import CommitGraph
import Foundation
import GitCore
import GitRunner
import RepositoryEngine

/// Measures ordering the history of `HEAD` from the repository's commit-graph,
/// for the roadmap's target of the first screen within 100 ms. Then it
/// measures what the app does: opening a session, ordering history from every
/// branch, remote branch and tag, and reading the text of the first screen.
struct HistoryBenchmark {
    var repository: String
    var sort = HistoryOrder.Sort.date
    var runs = 5
    var verify = false
    /// The rows in the first screen, as in the prototype.
    let screenRows = 100

    init(arguments: [String]) throws {
        var remaining = arguments[...]
        var repository: String?
        while let argument = remaining.popFirst() {
            switch argument {
            case "--sort":
                switch remaining.popFirst() {
                case "date": sort = .date
                case "topological": sort = .topological
                default: throw UsageError(description: "--sort takes date or topological")
                }
            case "--runs":
                guard let value = remaining.popFirst().flatMap(Int.init), value > 0 else {
                    throw UsageError(description: "--runs takes a positive number")
                }
                runs = value
            case "--verify":
                verify = true
            default:
                repository = argument
            }
        }
        guard let repository else { throw UsageError(description: "Name a repository") }
        self.repository = repository
    }

    func run() async throws {
        let git = Git(installation: try await GitInstallation.locate())
        let lines = try await git.text(GitCommand(
            "rev-parse", "--path-format=absolute", "--git-path", "objects", "--show-object-format", "HEAD",
            in: repository
        )).split(separator: "\n").map(String.init)
        guard lines.count == 3, let format = ObjectFormat(rawValue: lines[1]), let head = ObjectID(hex: lines[2]) else {
            throw UsageError(description: "Couldn't read the repository: \(lines)")
        }
        print("git \(git.installation.version), \(sort) order of HEAD in \(repository)")

        var timings: [String: [Duration]] = [:]
        var rows: [CommitGraph.Position] = []
        var graph: CommitGraph?
        var countedForFirstScreen = 0
        let clock = ContinuousClock()
        for _ in 0..<runs {
            var start = clock.now
            func lap(_ name: String) {
                let now = clock.now
                timings[name, default: []].append(now - start)
                start = now
            }
            let firstStart = start
            guard let opened = try CommitGraph(objectsFolder: lines[0], format: format) else {
                throw UsageError(description: "The repository has no commit-graph file")
            }
            guard let headPosition = opened.position(of: head) else {
                throw UsageError(description: "HEAD isn't in the commit-graph")
            }
            lap("open the commit-graph and find HEAD")
            var order = try HistoryOrder(graph: opened, tips: [headPosition], sort: sort)
            rows = try order.next(screenRows)
            lap("order the first screen")
            timings["first screen", default: []].append(clock.now - firstStart)
            countedForFirstScreen = order.countedCommitsSoFar
            rows += try order.next(Int.max)
            lap("order the rest")
            graph = opened
        }

        for name in ["open the commit-graph and find HEAD", "order the first screen", "first screen", "order the rest"] {
            let sorted = timings[name, default: []].sorted()
            let median = sorted[sorted.count / 2]
            print("  \(name): median \(milliseconds(median)), min \(milliseconds(sorted[0])), max \(milliseconds(sorted[sorted.count - 1]))")
        }
        print("  \(rows.count) commits of \(graph?.count ?? 0) in the graph; the first screen counted \(countedForFirstScreen)")

        let history = try await measureSession(git: git)

        if verify, let graph {
            print("Comparing with git log:")
            try await compare(rows, in: graph, withLogOf: ["HEAD"], git: git)
            try await compare(history.rows, in: history.graph, withLogOf: ["HEAD", "--branches", "--remotes", "--tags"], git: git)
        }
    }

    private func compare(
        _ rows: [CommitGraph.Position],
        in graph: CommitGraph,
        withLogOf names: [String],
        git: Git
    ) async throws {
        let option = sort == .date ? "--date-order" : "--topo-order"
        var index = 0
        var mismatches = 0
        let output = git.stream(GitCommand(["log", option, "--format=%H"] + names, in: repository))
        for try await line in output.records(separatedBy: UInt8(ascii: "\n")) {
            let id = ObjectID(hexDigits: line)
            if index >= rows.count || graph.id(at: rows[index]) != id {
                if mismatches == 0 { print("  first difference at row \(index)") }
                mismatches += 1
            }
            index += 1
        }
        mismatches += max(0, rows.count - index)
        print("  git log \(option) \(names.joined(separator: " ")): \(index) commits, \(mismatches) rows differ")
    }

    /// Times the steps the app takes to show history, which include running
    /// git to find the repository, its refs and any newer commits.
    private func measureSession(git: Git) async throws -> History {
        print("The app's session, from HEAD and every branch, remote branch and tag:")
        let names = ["open the session", "first screen", "the rest", "text for the first screen"]
        var timings: [String: [Duration]] = [:]
        var loaded: History?
        let clock = ContinuousClock()
        for _ in 0..<runs {
            var start = clock.now
            func lap(_ name: String) {
                let now = clock.now
                timings[name, default: []].append(now - start)
                start = now
            }
            let session = try await RepositorySession.open(containing: repository, git: git)
            lap("open the session")
            var first: History?
            var last: History?
            for try await history in session.history(sort: sort, firstRows: screenRows) {
                if first == nil {
                    first = history
                    lap("first screen")
                }
                last = history
            }
            lap("the rest")
            guard let first, let last else { throw UsageError(description: "The session loaded no history") }
            loaded = last
            _ = try await session.commits(first.rows.prefix(screenRows).map { first.graph.id(at: $0) })
            lap("text for the first screen")
            await session.close()
        }
        for name in names {
            let sorted = timings[name, default: []].sorted()
            let median = sorted[sorted.count / 2]
            print("  \(name): median \(milliseconds(median)), min \(milliseconds(sorted[0])), max \(milliseconds(sorted[sorted.count - 1]))")
        }
        guard let loaded else { throw UsageError(description: "The session loaded no history") }
        print("  \(loaded.rows.count) commits")
        return loaded
    }

    private func milliseconds(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.2f ms", milliseconds)
    }
}
