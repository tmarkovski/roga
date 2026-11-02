import CommitGraph
import Darwin
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
    var cold = false
    var parts = false
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
            case "--cold":
                cold = true
            case "--parts":
                parts = true
            default:
                repository = argument
            }
        }
        guard let repository else { throw UsageError(description: "Name a repository") }
        self.repository = repository
    }

    func run() async throws {
        let git = Git(installation: try await GitInstallation.locate())
        if cold {
            return parts ? try await measureColdParts(git: git) : try await measureColdStart(git: git)
        }
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

    /// Loads history once the way the app does, for running right after
    /// `sudo purge` empties the disk cache. Only the first load after that is
    /// cold, so this runs once, before anything else reads the repository,
    /// and reports how many pages each step had to read from disk.
    private func measureColdStart(git: Git) async throws {
        print("git \(git.installation.version), cold start in \(sort) order of \(repository)")
        print("The app's session, from HEAD and every branch, remote branch and tag:")
        let clock = ContinuousClock()
        let started = clock.now
        let startPages = PagesReadFromDisk.now()
        var stepStart = started
        var stepPages = startPages
        func lap(_ name: String) {
            let now = clock.now
            let pages = PagesReadFromDisk.now()
            print("  \(name): \(milliseconds(now - stepStart)), pages read from disk by yaga \(pages.own - stepPages.own), by git \(pages.git - stepPages.git)")
            stepStart = now
            stepPages = pages
        }

        let session = try await RepositorySession.open(containing: repository, git: git)
        lap("open the session")
        var firstScreen: ContinuousClock.Instant?
        var rows = 0
        for try await history in session.history(sort: sort, firstRows: screenRows) {
            rows = history.rows.count
            guard firstScreen == nil else { continue }
            lap("first screen")
            firstScreen = clock.now
            // Like the app, read the text while the rest is put in order, so
            // the pages read in this step include some of the rest's.
            _ = try await session.commits(history.rows.prefix(screenRows).map { history.graph.id(at: $0) })
            lap("text for the first screen")
            print("  first screen with its text, from the start: \(milliseconds(clock.now - started))")
        }
        lap("the rest of the \(rows) commits")
        if let firstScreen {
            print("  the rest was ready \(milliseconds(clock.now - firstScreen)) after the first screen")
        }

        // git's page reads count once yaga has waited for it to exit, so
        // cat-file's appear only after the session closes.
        await session.close()
        try await Task.sleep(for: .milliseconds(300))
        let end = PagesReadFromDisk.now()
        print("  in all, pages read from disk by yaga \(end.own - startPages.own), by git \(end.git - startPages.git), each \(getpagesize() / 1024) KB")
    }

    /// Takes the steps of loading history one at a time, from a cold disk
    /// cache, to show what each costs. The app lists refs and maps the
    /// commit-graph at the same time, but they read different files, so
    /// taking them one after the other shows how much each one waits for the
    /// disk.
    private func measureColdParts(git: Git) async throws {
        print("git \(git.installation.version), cold start in \(sort) order of \(repository), one part at a time:")
        let clock = ContinuousClock()
        let started = clock.now
        var stepStart = started
        var stepPages = PagesReadFromDisk.now()
        func lap(_ name: String) {
            let now = clock.now
            let pages = PagesReadFromDisk.now()
            print("  \(name): \(milliseconds(now - stepStart)), pages read from disk by yaga \(pages.own - stepPages.own), by git \(pages.git - stepPages.git)")
            stepStart = now
            stepPages = pages
        }

        let session = try await RepositorySession.open(containing: repository, git: git)
        lap("open the session")
        let refs = try await session.refs()
        lap("list the refs")
        guard let graph = try CommitGraph(objectsFolder: session.location.objectsFolder, format: session.location.format) else {
            throw UsageError(description: "The repository has no commit-graph file")
        }
        lap("map the commit-graph")
        // The same starting points as the app's: HEAD, then every branch,
        // remote branch and tag.
        let tips = ([refs.head].compactMap { $0 } + refs.refs.filter { $0.kind != .other }.map(\.peeled))
            .compactMap { graph.position(of: $0) }
        var order = try HistoryOrder(graph: graph, tips: tips, sort: sort)
        let rows = try order.next(screenRows)
        lap("order the first screen")
        _ = try await session.commits(rows.map { graph.id(at: $0) })
        lap("text for the first screen")
        print("  first screen with its text, from the start: \(milliseconds(clock.now - started))")
        await session.close()
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

/// The pages read from disk to resolve page faults, by yaga and by the git
/// processes it has waited for. A page that's already in the disk cache
/// doesn't count.
struct PagesReadFromDisk {
    var own: Int
    var git: Int

    static func now() -> PagesReadFromDisk {
        var own = rusage()
        var children = rusage()
        getrusage(RUSAGE_SELF, &own)
        getrusage(RUSAGE_CHILDREN, &children)
        return PagesReadFromDisk(own: own.ru_majflt, git: children.ru_majflt)
    }
}
