import CommitGraph
import Foundation
import GitCore
import GitRunner

/// A repository's history in order, at one moment.
public struct History: Sendable {
    public typealias Position = CommitGraph.Position

    /// Every commit, with its parents and dates.
    public var graph: CommitGraph
    public var refs: RefList
    public var sort: HistoryOrder.Sort
    /// The commits from top to bottom, each one as its position in `graph`.
    public var rows: [Position]
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
/// it puts the commits in order with `HistoryOrder`.
///
/// History shows the commits reachable from `HEAD` and from every branch,
/// remote branch and tag, which is what `git log HEAD --branches --remotes
/// --tags` shows.
struct HistoryLoader: Sendable {
    let git: Git
    let location: RepositoryLocation
    /// How many rows to put in order before the rest, so that the first
    /// screen can be drawn sooner.
    var firstRows = 200
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
        let refs = try await RefsLoader.load(git: git, location: location)
        guard canUseCommitGraphFiles(refs) else {
            return try await load(sort: sort, refs: refs, readingFiles: false, yield: yield)
        }
        do {
            try await load(sort: sort, refs: refs, readingFiles: true, yield: yield)
        } catch is CommitGraphError {
            // git ignores commit-graph files it can't read, and so does yaga.
            // It then lists every commit, which is slower but still right.
            try await load(sort: sort, refs: refs, readingFiles: false, yield: yield)
        }
    }

    private func load(
        sort: HistoryOrder.Sort,
        refs: RefList,
        readingFiles: Bool,
        yield: @Sendable (History) -> Void
    ) async throws {
        let stored = readingFiles ? try CommitGraph(objectsFolder: location.objectsFolder, format: location.format) : nil
        let tips = Self.tips(refs)
        let newer = try await newerCommits(tips: tips, graph: stored)
        let graph = try (stored ?? CommitGraph(format: location.format)).adding(newer)

        let tipPositions = tips.compactMap { graph.position(of: $0) }
        var order = try HistoryOrder(graph: graph, tips: tipPositions, sort: sort)
        var history = History(
            graph: graph,
            refs: refs,
            sort: sort,
            rows: try order.next(firstRows),
            isComplete: false,
            readCommitGraphFiles: stored != nil,
            refsByCommit: Self.refsByCommit(refs, in: graph),
            head: refs.head.flatMap { graph.position(of: $0) }
        )
        history.isComplete = order.isFinished
        yield(history)
        guard !history.isComplete else { return }

        history.rows.reserveCapacity(graph.count)
        while !order.isFinished {
            try Task.checkCancellation()
            history.rows += try order.next(rowsPerStep)
        }
        history.isComplete = true
        yield(history)
    }

    /// Whether git would use the commit-graph files. It doesn't in a shallow
    /// clone, or when replace refs or grafts change commits' parents, because
    /// the files have the parents the commits were made with.
    private func canUseCommitGraphFiles(_ refs: RefList) -> Bool {
        guard !location.isShallow else { return false }
        guard !refs.refs.contains(where: { $0.name.hasPrefix("refs/replace/") }) else { return false }
        return !FileManager.default.fileExists(atPath: location.commonDirectory + "/info/grafts")
    }

    /// Lists the commits reachable from `tips` that the commit-graph files
    /// don't have, with `git rev-list`. Tips the files have are excluded, so
    /// git stops where the newer commits meet the stored ones. Without files,
    /// that's every commit.
    private func newerCommits(tips: [ObjectID], graph: CommitGraph?) async throws -> [CommitGraph.NewerCommit] {
        var input = ""
        var seen: Set<ObjectID> = []
        var anyMissing = false
        for tip in tips where seen.insert(tip).inserted {
            if graph?.position(of: tip) == nil {
                input += tip.hex + "\n"
                anyMissing = true
            } else {
                input += "^" + tip.hex + "\n"
            }
        }
        guard anyMissing else { return [] }

        // Each line is the commit date, the commit and its parents. A list of
        // tips on standard input can't run into the limit on arguments.
        let command = GitCommand("rev-list", "--parents", "--timestamp", "--stdin", in: location.directory)
        var commits: [CommitGraph.NewerCommit] = []
        for try await line in git.stream(command, input: Array(input.utf8)).records(separatedBy: UInt8(ascii: "\n")) {
            guard let commit = Self.newerCommit(line) else {
                throw RepositoryError.unexpectedOutput(command, String(decoding: line, as: UTF8.self))
            }
            commits.append(commit)
        }
        return commits
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

    /// The commits history starts from: `HEAD`, then every branch, remote
    /// branch and tag that leads to a commit, in the order of their names, as
    /// git orders them for `git log HEAD --branches --remotes --tags`.
    static func tips(_ refs: RefList) -> [ObjectID] {
        var tips: [ObjectID] = []
        if let head = refs.head { tips.append(head) }
        for ref in refs.refs where ref.kind != .other {
            if let commit = ref.commit { tips.append(commit) }
        }
        return tips
    }

    /// The refs to show at each commit. Symbolic refs such as `origin/HEAD`
    /// are left out, because the ref they stand for is shown already.
    static func refsByCommit(_ refs: RefList, in graph: CommitGraph) -> [CommitGraph.Position: [Ref]] {
        var result: [CommitGraph.Position: [Ref]] = [:]
        for ref in refs.refs where ref.kind != .other && ref.symbolicTarget == nil {
            guard let commit = ref.commit, let position = graph.position(of: commit) else { continue }
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
