import Darwin
import GitCore

/// The commits in a repository's commit-graph, read from a single file or a
/// split chain, plus any commits newer than the files that were added to it.
///
/// Every commit has a position, from 0 to `count - 1`, and history refers to
/// commits by position rather than by ID. The commits stored in the files come
/// first, layer by layer from the base of a chain, and newer commits follow.
public struct CommitGraph: Sendable {
    public typealias Position = UInt32

    /// The kind of generation numbers that bound how far history has to be
    /// walked. Each commit's generation is higher than all of its parents'.
    enum Generations {
        /// Corrected commit dates, which git calls generation numbers v2.
        case correctedCommitDates
        /// Topological levels, which git calls generation numbers v1. git uses
        /// these when any layer of a chain lacks corrected commit dates.
        case topologicalLevels
        /// None, because the files were written before git stored them. Every
        /// commit then counts as infinitely high, and ordering walks all of
        /// history before it returns the first commit.
        case none
    }

    /// The generation of commits that have none, such as newer commits.
    static let infiniteGeneration = UInt64.max

    public let format: ObjectFormat
    /// The number of commits stored in the files.
    public let storedCount: Int
    var generations: Generations

    /// The layers of the chain, base first, or the single file.
    private let layers: [CommitGraphFile]
    /// The position of each layer's first commit.
    private let layerStarts: [Int]
    private var newer = NewerCommits()

    /// The number of commits, stored and newer.
    public var count: Int { storedCount + newer.ids.count }

    /// Makes a graph from a single file or the layers of a chain, base first,
    /// that have already been checked to fit together.
    init(format: ObjectFormat, layers: [CommitGraphFile]) {
        self.format = format
        self.layers = layers
        var starts: [Int] = []
        var total = 0
        for layer in layers {
            starts.append(total)
            total += layer.count
        }
        layerStarts = starts
        storedCount = total

        if layers.contains(where: { $0.count > 0 && $0.topologicalLevel(at: 0) == 0 }) {
            generations = .none
        } else if layers.allSatisfy(\.hasCorrectedCommitDates) {
            generations = .correctedCommitDates
        } else {
            generations = .topologicalLevels
        }
    }

    /// The paths of the files the commits are stored in, base first.
    public var paths: [String] { layers.map(\.path) }

    public func position(of id: ObjectID) -> Position? {
        // Recent commits are in the top layers, so search those first.
        for layer in layers.indices.reversed() {
            if let index = layers[layer].index(of: id) { return Position(layerStarts[layer] + index) }
        }
        return newer.positions[id]
    }

    public func id(at position: Position) -> ObjectID {
        if let (layer, index) = locate(position) { return layers[layer].id(at: index) }
        return newer.ids[Int(position) - storedCount]
    }

    /// The committer date, in seconds since 1970.
    public func commitTime(at position: Position) -> Int64 {
        if let (layer, index) = locate(position) { return layers[layer].commitTime(at: index) }
        return newer.commitTimes[Int(position) - storedCount]
    }

    /// The commit's parents, in order.
    public func parents(of position: Position) throws(CommitGraphError) -> [Position] {
        var parents: [Position] = []
        while let parent = try parent(of: position, at: parents.count) {
            parents.append(parent)
        }
        return parents
    }

    /// The commit's parent at `index`, or nil when it has fewer parents.
    /// Walks call this with indexes from 0 up until it returns nil, which
    /// saves them making an array for every commit.
    public func parent(of position: Position, at index: Int) throws(CommitGraphError) -> Position? {
        if let (layer, commit) = locate(position) {
            let limit = layerStarts[layer] + layers[layer].count
            return try layers[layer].parent(at: commit, index, limit: limit)
        }
        let newerIndex = Int(position) - storedCount
        let start = newerIndex == 0 ? 0 : Int(newer.parentEnds[newerIndex - 1])
        let end = Int(newer.parentEnds[newerIndex])
        return start + index < end ? newer.parents[start + index] : nil
    }

    /// The commit's generation number, which is higher than all of its
    /// parents', or `infiniteGeneration` for a commit that has none.
    func generation(at position: Position) throws(CommitGraphError) -> UInt64 {
        guard let (layer, index) = locate(position) else { return Self.infiniteGeneration }
        switch generations {
        case .correctedCommitDates: return try layers[layer].correctedCommitDate(at: index)
        case .topologicalLevels: return UInt64(layers[layer].topologicalLevel(at: index))
        case .none: return Self.infiniteGeneration
        }
    }

    /// The path of the file that stores a commit, for describing problems.
    func path(of position: Position) -> String? {
        locate(position).map { layers[$0.layer].path }
    }

    /// Finds the layer that stores a commit and the commit's index in it, or
    /// returns nil for a newer commit.
    @inline(__always)
    private func locate(_ position: Position) -> (layer: Int, index: Int)? {
        let position = Int(position)
        precondition(position < count, "Position \(position) is outside a commit-graph of \(count) commits")
        guard position < storedCount else { return nil }
        // Most chains have only a few layers, and the base holds most commits.
        var layer = 0
        while layer + 1 < layers.count && position >= layerStarts[layer + 1] {
            layer += 1
        }
        return (layer, position - layerStarts[layer])
    }
}

extension CommitGraph {
    /// A commit that isn't stored in the commit-graph files, such as one made
    /// since they were written.
    public struct NewerCommit: Sendable, Hashable {
        public var id: ObjectID
        public var parents: [ObjectID]
        /// The committer date, in seconds since 1970.
        public var commitTime: Int64

        public init(id: ObjectID, parents: [ObjectID], commitTime: Int64) {
            self.id = id
            self.parents = parents
            self.commitTime = commitTime
        }
    }

    /// Returns a graph that also has `commits`, at positions after the ones it
    /// already has. Commits it already has are skipped. Each parent has to be
    /// in the graph or among `commits`.
    public func adding(_ commits: [NewerCommit]) throws(CommitGraphError) -> CommitGraph {
        var graph = self
        var added: [NewerCommit] = []
        for commit in commits where graph.position(of: commit.id) == nil {
            guard commit.id.format == format else { throw .wrongFormat(commit.id) }
            graph.newer.positions[commit.id] = Position(graph.count)
            graph.newer.ids.append(commit.id)
            added.append(commit)
        }
        // Parents are looked up once every commit has a position, so that a
        // commit can come before its parents in the list.
        for commit in added {
            for parent in commit.parents {
                guard let position = graph.position(of: parent) else {
                    throw .missingParent(commit: commit.id, parent: parent)
                }
                graph.newer.parents.append(position)
            }
            graph.newer.parentEnds.append(UInt32(graph.newer.parents.count))
            graph.newer.commitTimes.append(commit.commitTime)
        }
        return graph
    }

    /// Newer commits, stored as one array per field. The parents of every
    /// commit are in one array, and each commit's parents end at its entry in
    /// `parentEnds`.
    private struct NewerCommits: Sendable {
        var ids: [ObjectID] = []
        var commitTimes: [Int64] = []
        var parentEnds: [UInt32] = []
        var parents: [Position] = []
        var positions: [ObjectID: Position] = [:]
    }
}

public enum CommitGraphError: Error, Hashable, CustomStringConvertible {
    /// A file couldn't be opened or read.
    case cannotRead(path: String, errorNumber: Int32)
    /// A file isn't a valid commit-graph file, or doesn't fit the chain it's
    /// in, or a commit in it points somewhere it can't.
    case invalid(path: String, reason: String)
    /// An ID uses a different hash function from the repository.
    case wrongFormat(ObjectID)
    /// A newer commit has a parent that's neither in the graph nor among the
    /// newer commits.
    case missingParent(commit: ObjectID, parent: ObjectID)

    public var description: String {
        switch self {
        case .cannotRead(let path, let errorNumber):
            "Couldn't read \(path): \(String(cString: strerror(errorNumber)))"
        case .invalid(let path, let reason):
            "\(path) isn't a valid commit-graph file. \(reason)"
        case .wrongFormat(let id):
            "\(id) is a \(id.format) ID, which doesn't match the repository."
        case .missingParent(let commit, let parent):
            "Commit \(commit) has a parent, \(parent), that isn't in the commit-graph."
        }
    }
}
