import CommitGraph
import GitCore
import GitRunner

/// A repository's history in order, at one moment.
public struct History: Sendable {
    public typealias Position = CommitGraph.Position

    /// Every commit, with its parents and dates.
    public var graph: CommitGraph
    public var refs: RefList
    public var sort: HistoryOrder.Sort
    /// The lines of the graph, and the rows they're laid out for.
    public var lanes: LaneLayout
    /// The commits from top to bottom, each one as its position in `graph`.
    public var rows: [Position] { lanes.rows }
    /// Whether `rows` has every commit yet, or only the first ones.
    public var isComplete: Bool
    /// Whether the commits came from the commit-graph files. When they
    /// didn't, git listed every commit, which is slow in a large repository.
    public var readCommitGraphFiles: Bool
    /// The branches, remote branches and tags at each commit, in the order to
    /// show them: the current branch, then branches, remote branches and tags.
    public var refsByCommit: [Position: [Ref]]
    /// The commit `HEAD` points to.
    public var head: Position?
}

/// Loads a repository's history: its refs, the commits in its commit-graph
/// files, and the commits newer than those, which `git rev-list` lists. Then
/// it puts the commits in order with `HistoryOrder`, and lays out the graph
/// with `LaneLayout`.
///
/// History shows the commits reachable from `HEAD` and from every branch,
/// remote branch and tag, which is what `git log HEAD --branches --remotes
/// --tags` shows.
struct HistoryLoader: Sendable {
    let git: Git
    let location: RepositoryLocation
    /// The worktree whose history to load. Each worktree has its own `HEAD`.
    let directory: String
    /// The session's `git cat-file`, for checking whether objects the
    /// commit-graph files don't have are commits.
    let catFile: CatFileSession
    /// How many rows to lay out before the rest, so that the first screen
    /// can be drawn sooner. A tall window shows about 60.
    var firstRows = 100
    /// How many rows to put in order between checks for cancellation.
    var rowsPerStep = 65_536

    /// Yields the history with its first rows as soon as those are in order,
    /// and then with all of them. Ending the iteration early stops loading.
    func load(sort: HistoryOrder.Sort) -> AsyncThrowingStream<History, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await load(sort: sort) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @concurrent
    private func load(sort: HistoryOrder.Sort, yield: @Sendable (History) -> Void) async throws {
        async let listedRefs = RefsLoader.load(git: git, in: directory)
        async let turnedOff = CommitGraphUpdate.Reason.isTurnedOffInGit(git: git, in: directory)
        // Map the commit-graph files while git lists the refs, so that reading
        // them from disk overlaps git's work. git ignores files it can't read,
        // and so does Roga. It then lists every commit, which is slower but
        // still right.
        let files = location.isShallow
            ? nil
            : try? CommitGraph(objectsFolder: location.objectsFolder, format: location.format)
        let refs = try await listedRefs
        guard try await !turnedOff, let files, CommitGraphUpdate.Reason.gitIgnoresFiles(in: location, refs: refs) == nil else {
            return try await load(sort: sort, refs: refs, files: nil, yield: yield)
        }
        do {
            try await load(sort: sort, refs: refs, files: files, yield: yield)
        } catch is CommitGraphError {
            try await load(sort: sort, refs: refs, files: nil, yield: yield)
        }
    }

    private func load(
        sort: HistoryOrder.Sort,
        refs: RefList,
        files stored: CommitGraph?,
        yield: @Sendable (History) -> Void
    ) async throws {
        let tips = Self.tips(refs)
        let newer = try await newerCommits(tips: tips, graph: stored)
        let graph = try (stored ?? CommitGraph(format: location.format)).adding(newer)

        let tipPositions = tips.compactMap { graph.position(of: $0) }
        var order = try HistoryOrder(graph: graph, tips: tipPositions, sort: sort)
        // The lanes of a row depend on the rows below it, as far as the
        // longest line drawn.
        let top = try order.next(firstRows + LaneLayout.longestLine)
        var lanes = LaneLayout(graph: graph)
        try lanes.append(top, isComplete: order.isFinished)
        var history = History(
            graph: graph,
            refs: refs,
            sort: sort,
            lanes: lanes,
            isComplete: order.isFinished,
            readCommitGraphFiles: stored != nil,
            refsByCommit: Self.refsByCommit(refs, in: graph),
            head: refs.head.flatMap { graph.position(of: $0) }
        )
        yield(history)
        guard !history.isComplete else { return }

        while !order.isFinished {
            try Task.checkCancellation()
            let rows = try order.next(rowsPerStep)
            try history.lanes.append(rows, isComplete: order.isFinished)
        }
        history.isComplete = true
        yield(history)
    }

    /// Lists the commits reachable from `tips` that the commit-graph files
    /// don't have, with `git rev-list`. Tips the files have are excluded, so
    /// git stops where the newer commits meet the stored ones. Without files,
    /// that's every commit.
    private func newerCommits(tips: [ObjectID], graph: CommitGraph?) async throws -> [CommitGraph.NewerCommit] {
        var seen: Set<ObjectID> = []
        let unique = tips.filter { seen.insert($0).inserted }
        let missing = if let graph {
            try await Self.commitsMissing(from: graph, tips: unique, catFile: catFile)
        } else {
            unique
        }
        guard !missing.isEmpty else { return [] }

        var input = ""
        for tip in missing {
            input += tip.hex + "\n"
        }
        if let graph {
            for tip in unique where graph.position(of: tip) != nil {
                input += "^" + tip.hex + "\n"
            }
        }

        // Each line is the commit date, the commit and its parents. A list of
        // tips on standard input can't run into the limit on arguments.
        let command = GitCommand("rev-list", "--parents", "--timestamp", "--stdin", in: directory)
        var commits: [CommitGraph.NewerCommit] = []
        for try await line in git.stream(command, input: Array(input.utf8)).records(separatedBy: UInt8(ascii: "\n")) {
            guard let commit = Self.newerCommit(line) else {
                throw RepositoryError.unexpectedOutput(command, String(decoding: line, as: UTF8.self))
            }
            commits.append(commit)
        }
        return commits
    }

    /// The commits among `tips` that the files don't have. A tag can lead to a
    /// tree or a blob, which the files don't have either. Asking git about
    /// those few is quicker than starting rev-list for nothing, which would
    /// ignore them anyway.
    static func commitsMissing(from graph: CommitGraph, tips: [ObjectID], catFile: CatFileSession) async throws -> [ObjectID] {
        let missing = tips.filter { graph.position(of: $0) == nil }
        guard !missing.isEmpty else { return [] }
        let objects = try await catFile.info(missing.map(\.hex))
        return zip(missing, objects).compactMap { tip, object in object?.type == .commit ? tip : nil }
    }

    static func newerCommit(_ line: ArraySlice<UInt8>) -> CommitGraph.NewerCommit? {
        let fields = line.split(separator: UInt8(ascii: " "))
        guard fields.count >= 2, let time = integer(fields[0]), let id = ObjectID(hexDigits: fields[1]) else {
            return nil
        }
        var parents: [ObjectID] = []
        parents.reserveCapacity(fields.count - 2)
        for field in fields.dropFirst(2) {
            guard let parent = ObjectID(hexDigits: field) else { return nil }
            parents.append(parent)
        }
        return CommitGraph.NewerCommit(id: id, parents: parents, commitTime: time)
    }

    private static func integer(_ digits: ArraySlice<UInt8>) -> Int64? {
        guard !digits.isEmpty, digits.count <= 18 else { return nil }
        var value: Int64 = 0
        for digit in digits {
            guard digit >= UInt8(ascii: "0"), digit <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int64(digit - UInt8(ascii: "0"))
        }
        return value
    }

    /// The commits history starts from: `HEAD`, then what every branch,
    /// remote branch and tag leads to, in the order of their names, as git
    /// orders them for `git log HEAD --branches --remotes --tags`. Anything
    /// that isn't a commit is left out later, because it has no position.
    static func tips(_ refs: RefList) -> [ObjectID] {
        var tips: [ObjectID] = []
        if let head = refs.head { tips.append(head) }
        for ref in refs.refs where ref.kind != .other {
            tips.append(ref.peeled)
        }
        return tips
    }

    /// The refs to show at each commit. Symbolic refs such as `origin/HEAD`
    /// are left out, because the ref they stand for is shown already.
    static func refsByCommit(_ refs: RefList, in graph: CommitGraph) -> [CommitGraph.Position: [Ref]] {
        var result: [CommitGraph.Position: [Ref]] = [:]
        for ref in refs.refs where ref.kind != .other && ref.symbolicTarget == nil {
            guard let position = graph.position(of: ref.peeled) else { continue }
            result[position, default: []].append(ref)
        }
        func rank(_ ref: Ref) -> Int {
            if ref.name == refs.currentBranch { return 0 }
            switch ref.kind {
            case .branch: return 1
            case .remoteBranch: return 2
            case .tag: return 3
            case .other: return 4
            }
        }
        for (position, list) in result where list.count > 1 {
            // The list is already sorted by name, and a stable sort keeps that
            // order within each kind.
            result[position] = list.enumerated()
                .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
                .map(\.element)
        }
        return result
    }
}
